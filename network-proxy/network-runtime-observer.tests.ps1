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

$python = Get-Command python -ErrorAction Stop
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
            ('codex_core::responses_retry', 'max_retries=8 sampling_error=failed to send websocket request', 'pid:1234:current'),
            ('codex_core::responses_retry', 'max_retries=8 sampling_error=error decoding response body', 'pid:9999:other'),
            ('codex_core::responses_retry', 'max_retries=5 sampling_error=error decoding response body', 'pid:1234:current'),
            ('codex_core::responses_retry', 'turn_id=11111111-1111-1111-1111-111111111111 retries=1 max_retries=8 sampling_error=Transport error: network error: error decoding response body', 'pid:1234:current'),
        ]
    elif action == 'append':
        rows = [
            ('codex_core::responses_retry', 'turn_id=22222222-2222-2222-2222-222222222222 retries=2 max_retries=8 sampling_error=error sending request for url (https://chatgpt.com/backend-api/codex/responses)', 'pid:1234:current'),
        ]
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
    & $python.Source -c $fixtureScript $databasePath init
    if ($LASTEXITCODE -ne 0) { throw '无法创建 SQLite 观察器测试夹具。' }
    $databaseHashBefore = (Get-FileHash -LiteralPath $databasePath -Algorithm SHA256).Hash

    $first = Get-CodexRuntimeNetworkEvents -DatabasePath $databasePath -CursorPath $cursorPath `
        -ActiveProcessIds 1234 -ExpectedMaxRetries 8 -BootstrapRows 100
    Assert-True $first.Available 'Windows winsqlite3 只读观察器必须能读取测试数据库。'
    Assert-True $first.Bootstrapped '首次观察必须使用有界日志尾部建立游标。'
    Assert-Equal @($first.Events).Count 1 '观察器必须只保留当前桌面核心的托管 HTTP/SSE 错误。'
    Assert-Equal $first.Events[0].Class 'ResponseBodyDecode' '响应体截断必须识别为强长流故障。'
    Assert-Equal $first.Events[0].ProcessId 1234 '事件必须绑定当前活动 Codex 核心 PID。'

    $second = Get-CodexRuntimeNetworkEvents -DatabasePath $databasePath -CursorPath $cursorPath `
        -ActiveProcessIds 1234 -ExpectedMaxRetries 8
    Assert-Equal @($second.Events).Count 0 '持久游标必须防止重启或轮询重复统计同一错误。'

    & $python.Source -c $fixtureScript $databasePath append
    if ($LASTEXITCODE -ne 0) { throw '无法追加 SQLite 观察器测试夹具。' }
    $databaseHashAfterAppend = (Get-FileHash -LiteralPath $databasePath -Algorithm SHA256).Hash
    $third = Get-CodexRuntimeNetworkEvents -DatabasePath $databasePath -CursorPath $cursorPath `
        -ActiveProcessIds 1234 -ExpectedMaxRetries 8
    Assert-Equal @($third.Events).Count 1 '新增的当前 HTTP/SSE 发送错误必须被观察一次。'
    Assert-Equal $third.Events[0].Class 'RequestSend' '请求发送故障必须进入长流故障策略。'
    Assert-Equal (Get-FileHash -LiteralPath $databasePath -Algorithm SHA256).Hash $databaseHashAfterAppend '观察器必须以只读方式打开 Codex 日志数据库。'
    Assert-True ($databaseHashBefore -ne $databaseHashAfterAppend) '测试夹具追加必须真实改变数据库，避免只读断言失效。'

    $cursorHashBeforeRecentScan = (Get-FileHash -LiteralPath $cursorPath -Algorithm SHA256).Hash
    $recentBeforeBurst = Get-CodexRecentRuntimeNetworkEvents -DatabasePath $databasePath `
        -ActiveProcessIds 1234 -ExpectedMaxRetries 8 -FailureWindow ([TimeSpan]::FromMinutes(10)) -MaxScanRows 1000
    Assert-True $recentBeforeBurst.Available '近期故障扫描必须能独立于增量游标读取活动核心。'
    $healthy = Get-CodexRuntimeNetworkDegradation -Events $recentBeforeBurst.Events `
        -FailureThreshold 3 -FailureWindow ([TimeSpan]::FromMinutes(10))
    Assert-True (-not $healthy.Degraded) '两个不同任务的断流仍属于可恢复抖动，不得触发换路。'
    Assert-Equal $healthy.DistinctTurnCount 2 '阈值必须按不同任务计数，不能按重试次数放大。'

    & $python.Source -c $fixtureScript $databasePath burst
    if ($LASTEXITCODE -ne 0) { throw '无法追加原生路径退化测试夹具。' }
    $databaseHashAfterBurst = (Get-FileHash -LiteralPath $databasePath -Algorithm SHA256).Hash
    $recentAfterBurst = Get-CodexRecentRuntimeNetworkEvents -DatabasePath $databasePath `
        -ActiveProcessIds 1234 -ExpectedMaxRetries 8 -FailureWindow ([TimeSpan]::FromMinutes(10)) -MaxScanRows 1000
    $degraded = Get-CodexRuntimeNetworkDegradation -Events $recentAfterBurst.Events `
        -FailureThreshold 3 -FailureWindow ([TimeSpan]::FromMinutes(10))
    Assert-True $degraded.Degraded '十分钟内三个不同任务断流必须判定为实质性路径退化。'
    Assert-Equal $degraded.DistinctTurnCount 3 '同一任务多次重试必须只计一个退化样本。'
    Assert-Equal (Get-FileHash -LiteralPath $cursorPath -Algorithm SHA256).Hash $cursorHashBeforeRecentScan '近期只读扫描不得推进或改写增量游标。'
    Assert-Equal (Get-FileHash -LiteralPath $databasePath -Algorithm SHA256).Hash $databaseHashAfterBurst '近期扫描不得修改 Codex 日志数据库。'

    [IO.File]::WriteAllText($cursorPath, '{broken-json', [Text.UTF8Encoding]::new($false))
    $recovered = Get-CodexRuntimeNetworkEvents -DatabasePath $databasePath -CursorPath $cursorPath `
        -ActiveProcessIds 1234 -ExpectedMaxRetries 8
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
