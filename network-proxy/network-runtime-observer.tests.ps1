$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'network-runtime-observer.psm1') -Force

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [Parameter(Mandatory = $true)][string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected=[$Expected] Actual=[$Actual]" }
}

function Resolve-TestPythonExecutable {
    $candidates = @(
        @(Get-Command py -All -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Source = $_.Source; Arguments = @('-3') }
        })
        @(Get-Command python -All -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Source = $_.Source; Arguments = @() }
        })
        @(Get-Command python3 -All -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Source = $_.Source; Arguments = @() }
        })
    )
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        $candidateArguments = @($candidate.Arguments)
        $key = "$($candidate.Source)|$($candidateArguments -join ' ')"
        if (-not $seen.Add($key)) { continue }
        try {
            $probeOutput = @(& $candidate.Source @candidateArguments -c 'import sys; print(sys.executable)' 2>$null)
            if ($LASTEXITCODE -ne 0 -or $probeOutput.Count -eq 0) { continue }
            $resolved = ([string]$probeOutput[-1]).Trim()
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { continue }
            & $resolved -c 'import sqlite3' 2>$null
            if ($LASTEXITCODE -eq 0) { return [IO.Path]::GetFullPath($resolved) }
        }
        catch { }
    }
    throw '未找到可启动且包含 sqlite3 的 Python 3 解释器。'
}

$module = Get-Module 'network-runtime-observer'
$decodeBody = 'turn_id=01a08683-ce97-7ae2-b838-7cb759de456f retries=1 max_retries=8 sampling_error=stream disconnected before completion: Transport error: network error: error decoding response body'
$classified = @(& $module {
    param($Body)
    $active = [Collections.Generic.HashSet[int]]::new()
    [void]$active.Add(81824)
    foreach ($transport in @('Unknown', 'WebSocket')) {
        ConvertTo-CodexRuntimeNetworkEvent -Row ([pscustomobject]@{
            Id=111970829; Timestamp=1788963897; ProcessUuid='pid:81824:fixture';
            Body=$Body; Transport=$transport
        }) -ActiveProcessIds $active -IncludeWebSocket
    }
    foreach ($bodyText in @(($Body + ' transport="responses_websocket"'), $Body.Replace('error decoding response body', 'request timed out'))) {
        ConvertTo-CodexRuntimeNetworkEvent -Row ([pscustomobject]@{
            Id=111970830; Timestamp=1788963897; ProcessUuid='pid:81824:fixture';
            Body=$bodyText; Transport='Unknown'
        }) -ActiveProcessIds $active -IncludeWebSocket
    }
} $decodeBody)
Assert-Equal $classified[0].Transport 'HttpSse' 'Response body decode failure must be recognized without endpoint logs.'
Assert-Equal $classified[1].Transport 'WebSocket' 'Explicit endpoint evidence must take priority.'
Assert-Equal $classified[2].Transport 'WebSocket' 'Explicit WebSocket text must take priority.'
Assert-Equal $classified[3].Transport 'Unknown' 'Generic timeouts must remain unknown.'

$replayNow = [DateTime]'2026-09-09T14:30:00Z'
$firstFailure = $classified[0]
$secondFailure = $firstFailure.PSObject.Copy()
$secondFailure.LogId = 111971004
$secondFailure.Retry = 2
$secondFailure.TimestampUtc = $firstFailure.TimestampUtc.AddSeconds(301)
$replayed = Get-CodexRuntimeNetworkDegradation -Events @($firstFailure, $secondFailure) -NowUtc $replayNow
Assert-True $replayed.FailoverRequired 'The observed five-minute repeated HTTP failure must request alternate-route verification.'
Assert-Equal $replayed.PersistentTurnCount 1 'Persistent failures must be counted per process and turn.'
$secondFailure.Retry = 1
Assert-True (-not (Get-CodexRuntimeNetworkDegradation -Events @($firstFailure, $secondFailure) -NowUtc $replayNow).FailoverRequired) 'Duplicate retries must not trigger persistent failure.'
$secondFailure.Retry = 2
$secondFailure.ProcessUuid = 'pid:81825:other'
Assert-True (-not (Get-CodexRuntimeNetworkDegradation -Events @($firstFailure, $secondFailure) -NowUtc $replayNow).FailoverRequired) 'Separate cores must not combine into a persistent turn.'
$secondFailure.ProcessUuid = $firstFailure.ProcessUuid
$secondFailure.TimestampUtc = $firstFailure.TimestampUtc.AddSeconds(20)
Assert-True (-not (Get-CodexRuntimeNetworkDegradation -Events @($firstFailure, $secondFailure) -NowUtc $replayNow).FailoverRequired) 'Short retry bursts must not trigger persistent failure.'

$pythonPath = Resolve-TestPythonExecutable
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-runtime-observer-test-$PID-$([Guid]::NewGuid().ToString('N'))")
$databasePath = Join-Path $testRoot 'logs.sqlite'
$cursorPath = Join-Path $testRoot 'runtime-cursor.json'
$fixtureScript = @'
import sqlite3
import sys
import time

database, action = sys.argv[1], sys.argv[2]
connection = sqlite3.connect(database)
try:
    if action == 'init':
        connection.execute('CREATE TABLE logs (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, ts_nanos INTEGER NOT NULL, level TEXT NOT NULL, target TEXT NOT NULL, feedback_log_body TEXT, module_path TEXT, file TEXT, line INTEGER, thread_id TEXT, process_uuid TEXT, estimated_bytes INTEGER NOT NULL DEFAULT 0)')
        rows = [
            ('other', 'not relevant', 'pid:1234:current'),
            ('codex_api::endpoint::responses_websocket', 'turn_id=44444444-4444-4444-4444-444444444444 transport="responses_websocket"', 'pid:1234:current'),
            ('codex_core::responses_retry', 'turn_id=44444444-4444-4444-4444-444444444444 retries=5 max_retries=5 sampling_error=request timed out', 'pid:1234:current'),
            ('codex_core::responses_retry', 'max_retries=8 sampling_error=error decoding response body', 'pid:9999:other'),
            ('codex_http_client::request', 'turn_id=11111111-1111-1111-1111-111111111111 transport="responses_http"', 'pid:1234:current'),
            ('codex_core::responses_retry', 'turn_id=11111111-1111-1111-1111-111111111111 retries=1 max_retries=5 sampling_error=error decoding response body', 'pid:1234:current'),
            ('codex_core::responses_retry', 'turn_id=11111111-1111-1111-1111-111111111111 retries=2 max_retries=8 sampling_error=Transport error: network error: error decoding response body', 'pid:1234:current'),
        ]
    elif action == 'append':
        rows = [
            ('codex_core::responses_retry', 'turn_id=22222222-2222-2222-2222-222222222222 retries=2 max_retries=8 sampling_error=error sending request for url (https://chatgpt.com/backend-api/codex/responses)', 'pid:1234:current'),
        ]
    elif action == 'dense':
        rows = [
            ('codex_api::endpoint::responses_websocket', 'turn_id=66666666-6666-6666-6666-666666666666 transport="responses_websocket"', 'pid:1234:current'),
        ]
        rows.extend([
            ('other', 'high-volume unrelated runtime log', 'pid:1234:current')
            for _ in range(12050)
        ])
        rows.append(
            ('codex_core::responses_retry', 'turn_id=66666666-6666-6666-6666-666666666666 retries=5 max_retries=5 sampling_error=request timed out', 'pid:1234:current')
        )
    elif action == 'burst':
        rows = [
            ('codex_core::responses_retry', 'turn_id=22222222-2222-2222-2222-222222222222 retries=3 max_retries=8 sampling_error=error sending request for url (https://chatgpt.com/backend-api/codex/responses)', 'pid:1234:current'),
            ('codex_core::responses_retry', 'turn_id=33333333-3333-3333-3333-333333333333 retries=1 max_retries=8 sampling_error=Transport error: network error: error decoding response body', 'pid:1234:current'),
        ]
    else:
        raise RuntimeError('unknown fixture action')
    now = int(time.time())
    connection.executemany(
        'INSERT INTO logs(ts, ts_nanos, level, target, feedback_log_body, process_uuid) VALUES(?, 0, ?, ?, ?, ?)',
        [(now, 'WARN', target, body, process_uuid) for target, body, process_uuid in rows],
    )
    connection.commit()
finally:
    connection.close()
'@

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    & $pythonPath -c $fixtureScript $databasePath init
    if ($LASTEXITCODE -ne 0) { throw '无法创建 SQLite 观察器测试夹具。' }
    $databaseHashBefore = (Get-FileHash -LiteralPath $databasePath -Algorithm SHA256).Hash

    $first = Get-CodexRuntimeNetworkEvents -DatabasePath $databasePath -CursorPath $cursorPath `
        -ActiveProcessIds 1234 -BootstrapRows 100
    Assert-True $first.Available 'Windows winsqlite3 只读观察器必须能读取测试数据库。'
    Assert-True $first.Bootstrapped '首次观察必须使用有界日志尾部建立游标。'
    Assert-Equal @($first.Events).Count 2 '动态预算观察器必须接受当前桌面核心的 5 次和 8 次 HTTP/SSE 错误。'
    Assert-True (@($first.Events | Where-Object MaxRetries -eq 5).Count -eq 1) 'Codex 更新后的 5 次重试预算不得漏报。'
    Assert-True (@($first.Events | Where-Object MaxRetries -eq 8).Count -eq 1) '补丁 provider 的 8 次重试预算必须继续识别。'
    Assert-True (@($first.Events | Where-Object Transport -ne 'HttpSse').Count -eq 0) '默认观察必须排除 WebSocket 噪声。'
    Assert-Equal $first.Events[0].ProcessId 1234 '事件必须绑定当前活动 Codex 核心 PID。'

    $exactBudget = Get-CodexRecentRuntimeNetworkEvents -DatabasePath $databasePath `
        -ActiveProcessIds 1234 -ExpectedMaxRetries 8 -FailureWindow ([TimeSpan]::FromMinutes(10)) -MaxScanRows 1000
    Assert-Equal @($exactBudget.Events).Count 1 '显式预算过滤仍必须可用于有界兼容诊断。'
    $transportAware = Get-CodexRecentRuntimeNetworkEvents -DatabasePath $databasePath `
        -ActiveProcessIds 1234 -IncludeWebSocket -FailureWindow ([TimeSpan]::FromMinutes(10)) -MaxScanRows 1000
    $webSocketEvents = @($transportAware.Events | Where-Object Transport -eq 'WebSocket')
    Assert-Equal $webSocketEvents.Count 1 '按需诊断必须暴露旧任务仍在使用的 WebSocket 重试。'
    Assert-True $webSocketEvents[0].RetriesExhausted '达到动态 max_retries 时必须标记重试耗尽。'

    $second = Get-CodexRuntimeNetworkEvents -DatabasePath $databasePath -CursorPath $cursorPath `
        -ActiveProcessIds 1234
    Assert-Equal @($second.Events).Count 0 '持久游标必须防止重启或轮询重复统计同一错误。'

    & $pythonPath -c $fixtureScript $databasePath append
    if ($LASTEXITCODE -ne 0) { throw '无法追加 SQLite 观察器测试夹具。' }
    $databaseHashAfterAppend = (Get-FileHash -LiteralPath $databasePath -Algorithm SHA256).Hash
    $third = Get-CodexRuntimeNetworkEvents -DatabasePath $databasePath -CursorPath $cursorPath `
        -ActiveProcessIds 1234
    Assert-Equal @($third.Events).Count 1 '新增的当前 HTTP/SSE 发送错误必须被观察一次。'
    Assert-Equal $third.Events[0].Class 'RequestSend' '请求发送故障必须进入长流故障策略。'
    Assert-Equal (Get-FileHash -LiteralPath $databasePath -Algorithm SHA256).Hash $databaseHashAfterAppend '观察器必须以只读方式打开 Codex 日志数据库。'
    Assert-True ($databaseHashBefore -ne $databaseHashAfterAppend) '测试夹具追加必须真实改变数据库，避免只读断言失效。'

    & $pythonPath -c $fixtureScript $databasePath dense
    if ($LASTEXITCODE -ne 0) { throw '无法追加高吞吐传输关联测试夹具。' }
    $dense = Get-CodexRuntimeNetworkEvents -DatabasePath $databasePath -CursorPath $cursorPath `
        -ActiveProcessIds 1234 -IncludeWebSocket
    Assert-Equal @($dense.Events).Count 1 '传输关联不得因同一核心短时产生超过一万条无关日志而失效。'
    Assert-Equal $dense.Events[0].Transport 'WebSocket' '高吞吐日志下仍必须识别历史任务的 WebSocket 传输。'
    Assert-True $dense.Events[0].RetriesExhausted '高吞吐日志下仍必须保留动态重试耗尽证据。'

    $cursorHashBeforeRecentScan = (Get-FileHash -LiteralPath $cursorPath -Algorithm SHA256).Hash
    $recentBeforeBurst = Get-CodexRecentRuntimeNetworkEvents -DatabasePath $databasePath `
        -ActiveProcessIds 1234 -FailureWindow ([TimeSpan]::FromMinutes(10)) -MaxScanRows 20000
    Assert-True $recentBeforeBurst.Available '近期故障扫描必须能独立于增量游标读取活动核心。'
    $healthy = Get-CodexRuntimeNetworkDegradation -Events $recentBeforeBurst.Events `
        -FailureThreshold 3 -FailureWindow ([TimeSpan]::FromMinutes(10))
    Assert-True (-not $healthy.Degraded) '两个不同任务的断流仍属于可恢复抖动，不得触发换路。'
    Assert-True (-not $healthy.FailoverRequired) '未耗尽重试且未跨任务退化时不得切换线路。'
    Assert-Equal $healthy.DistinctTurnCount 2 '阈值必须按不同任务计数，不能按重试次数放大。'

    $nowUtc = [DateTime]::UtcNow
    $exhausted = Get-CodexRuntimeNetworkDegradation -Events @([pscustomobject]@{
        TimestampUtc = $nowUtc
        TurnId = '55555555-5555-5555-5555-555555555555'
        LogId = 500
        RetriesExhausted = $true
        Error = 'request timed out'
    }) -FailureThreshold 3 -FailureWindow ([TimeSpan]::FromMinutes(10)) -NowUtc $nowUtc
    Assert-True (-not $exhausted.Degraded) '单个任务重试耗尽不等同于跨任务退化。'
    Assert-True $exhausted.FailoverRequired '单个 HTTPS/SSE 任务耗尽全部重试后必须要求验证备用线路。'
    Assert-Equal $exhausted.ExhaustedTurnCount 1 '重试耗尽必须按任务去重。'

    & $pythonPath -c $fixtureScript $databasePath burst
    if ($LASTEXITCODE -ne 0) { throw '无法追加原生路径退化测试夹具。' }
    $databaseHashAfterBurst = (Get-FileHash -LiteralPath $databasePath -Algorithm SHA256).Hash
    $recentAfterBurst = Get-CodexRecentRuntimeNetworkEvents -DatabasePath $databasePath `
        -ActiveProcessIds 1234 -FailureWindow ([TimeSpan]::FromMinutes(10)) -MaxScanRows 20000
    $degraded = Get-CodexRuntimeNetworkDegradation -Events $recentAfterBurst.Events `
        -FailureThreshold 3 -FailureWindow ([TimeSpan]::FromMinutes(10))
    Assert-True $degraded.Degraded '十分钟内三个不同任务断流必须判定为实质性路径退化。'
    Assert-True $degraded.FailoverRequired '跨任务退化必须要求验证备用线路。'
    Assert-Equal $degraded.DistinctTurnCount 3 '同一任务多次重试必须只计一个退化样本。'
    Assert-Equal (Get-FileHash -LiteralPath $cursorPath -Algorithm SHA256).Hash $cursorHashBeforeRecentScan '近期只读扫描不得推进或改写增量游标。'
    Assert-Equal (Get-FileHash -LiteralPath $databasePath -Algorithm SHA256).Hash $databaseHashAfterBurst '近期扫描不得修改 Codex 日志数据库。'

    [IO.File]::WriteAllText($cursorPath, '{broken-json', [Text.UTF8Encoding]::new($false))
    $recovered = Get-CodexRuntimeNetworkEvents -DatabasePath $databasePath -CursorPath $cursorPath `
        -ActiveProcessIds 1234
    Assert-True $recovered.Available '游标损坏不得使网络守护永久失效。'
    Assert-True $recovered.CursorRecovered '损坏游标必须显式报告安全恢复。'
    Assert-Equal @($recovered.Events).Count 0 '游标损坏时不得重放历史任务并误触发熔断。'
    $cursorStatus = Get-CodexRuntimeNetworkCursorStatus -CursorPath $cursorPath
    Assert-True $cursorStatus.Healthy '安全恢复后的游标必须可再次读取。'
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $resolvedTestRoot.StartsWith($resolvedTempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理临时目录边界外的测试路径：$resolvedTestRoot"
    }
    if (Test-Path -LiteralPath $resolvedTestRoot -PathType Container) {
        [IO.Directory]::Delete($resolvedTestRoot, $true)
    }
}

'network-runtime-observer tests: PASS'
