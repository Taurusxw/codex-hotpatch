Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-CodexWinsqliteReader {
    if ($null -ne ('CodexHotpatch.NetworkLogReaderV1' -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexHotpatch
{
    public sealed class NetworkLogRow
    {
        public long Id { get; private set; }
        public long Timestamp { get; private set; }
        public string ProcessUuid { get; private set; }
        public string Body { get; private set; }
        public string Transport { get; private set; }

        public NetworkLogRow(long id, long timestamp, string processUuid, string body, string transport)
        {
            Id = id;
            Timestamp = timestamp;
            ProcessUuid = processUuid;
            Body = body;
            Transport = transport;
        }
    }

    public static class NetworkLogReaderV1
    {
        private const int SqliteOk = 0;
        private const int SqliteRow = 100;
        private const int SqliteDone = 101;
        private const int SqliteOpenReadOnly = 1;

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_open_v2(byte[] filename, out IntPtr database, int flags, IntPtr vfs);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close_v2(IntPtr database);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_busy_timeout(IntPtr database, int milliseconds);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_prepare_v2(IntPtr database, byte[] sql, int byteCount, out IntPtr statement, IntPtr tail);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern long sqlite3_column_int64(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_text(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_bytes(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_errmsg(IntPtr database);

        private static byte[] Utf8Z(string value)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value);
            byte[] terminated = new byte[bytes.Length + 1];
            Buffer.BlockCopy(bytes, 0, terminated, 0, bytes.Length);
            return terminated;
        }

        private static string ReadUtf8(IntPtr pointer, int byteCount)
        {
            if (pointer == IntPtr.Zero || byteCount <= 0) { return String.Empty; }
            byte[] bytes = new byte[byteCount];
            Marshal.Copy(pointer, bytes, 0, byteCount);
            return Encoding.UTF8.GetString(bytes);
        }

        private static string GetError(IntPtr database)
        {
            if (database == IntPtr.Zero) { return "unknown SQLite error"; }
            IntPtr pointer = sqlite3_errmsg(database);
            if (pointer == IntPtr.Zero) { return "unknown SQLite error"; }
            int length = 0;
            while (Marshal.ReadByte(pointer, length) != 0) { length++; }
            return ReadUtf8(pointer, length);
        }

        private static IntPtr OpenReadOnly(string path)
        {
            IntPtr database;
            int result = sqlite3_open_v2(Utf8Z(path), out database, SqliteOpenReadOnly, IntPtr.Zero);
            if (result != SqliteOk)
            {
                string error = GetError(database);
                if (database != IntPtr.Zero) { sqlite3_close_v2(database); }
                throw new InvalidOperationException("SQLite read-only open failed: " + error);
            }
            sqlite3_busy_timeout(database, 1500);
            return database;
        }

        private static IntPtr Prepare(IntPtr database, string sql)
        {
            IntPtr statement;
            int result = sqlite3_prepare_v2(database, Utf8Z(sql), -1, out statement, IntPtr.Zero);
            if (result != SqliteOk)
            {
                throw new InvalidOperationException("SQLite prepare failed: " + GetError(database));
            }
            return statement;
        }

        public static long GetMaxLogId(string path)
        {
            IntPtr database = IntPtr.Zero;
            IntPtr statement = IntPtr.Zero;
            try
            {
                database = OpenReadOnly(path);
                statement = Prepare(database, "SELECT COALESCE(MAX(id), 0) FROM logs");
                int result = sqlite3_step(statement);
                if (result != SqliteRow)
                {
                    throw new InvalidOperationException("SQLite max(id) query failed: " + GetError(database));
                }
                return sqlite3_column_int64(statement, 0);
            }
            finally
            {
                if (statement != IntPtr.Zero) { sqlite3_finalize(statement); }
                if (database != IntPtr.Zero) { sqlite3_close_v2(database); }
            }
        }

        public static NetworkLogRow[] ReadRetryRows(string path, long lowerExclusive, long upperInclusive)
        {
            if (upperInclusive <= lowerExclusive) { return new NetworkLogRow[0]; }

            string sql = String.Format(
                System.Globalization.CultureInfo.InvariantCulture,
                "SELECT retry.id, retry.ts, retry.process_uuid, retry.feedback_log_body, " +
                "COALESCE((SELECT CASE endpoint.target " +
                "WHEN 'codex_api::endpoint::responses_websocket' THEN 'WebSocket' " +
                "WHEN 'codex_http_client::request' THEN 'HttpSse' END " +
                "FROM logs endpoint WHERE endpoint.process_uuid = retry.process_uuid " +
                "AND endpoint.id < retry.id AND endpoint.ts >= retry.ts - 300 AND endpoint.ts <= retry.ts " +
                "AND endpoint.target IN ('codex_api::endpoint::responses_websocket', 'codex_http_client::request') " +
                "AND instr(endpoint.feedback_log_body, 'turn_id=' || substr(retry.feedback_log_body, instr(retry.feedback_log_body, 'turn_id=') + 8, 36)) > 0 " +
                "ORDER BY endpoint.id DESC LIMIT 1), 'Unknown') " +
                "FROM logs retry WHERE retry.id > {0} AND retry.id <= {1} " +
                "AND retry.target = 'codex_core::responses_retry' ORDER BY retry.id",
                lowerExclusive,
                upperInclusive);
            IntPtr database = IntPtr.Zero;
            IntPtr statement = IntPtr.Zero;
            List<NetworkLogRow> rows = new List<NetworkLogRow>();
            try
            {
                database = OpenReadOnly(path);
                statement = Prepare(database, sql);
                while (true)
                {
                    int result = sqlite3_step(statement);
                    if (result == SqliteDone) { break; }
                    if (result != SqliteRow)
                    {
                        throw new InvalidOperationException("SQLite retry query failed: " + GetError(database));
                    }
                    string processUuid = ReadUtf8(sqlite3_column_text(statement, 2), sqlite3_column_bytes(statement, 2));
                    string body = ReadUtf8(sqlite3_column_text(statement, 3), sqlite3_column_bytes(statement, 3));
                    string transport = ReadUtf8(sqlite3_column_text(statement, 4), sqlite3_column_bytes(statement, 4));
                    rows.Add(new NetworkLogRow(
                        sqlite3_column_int64(statement, 0),
                        sqlite3_column_int64(statement, 1),
                        processUuid,
                        body,
                        transport));
                }
                return rows.ToArray();
            }
            finally
            {
                if (statement != IntPtr.Zero) { sqlite3_finalize(statement); }
                if (database != IntPtr.Zero) { sqlite3_close_v2(database); }
            }
        }
    }
}
'@
}

function Get-CodexRuntimeCursorMutexName {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = [IO.Path]::GetFullPath($Path).ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))
    }
    finally {
        $sha.Dispose()
    }
    return 'Local\CodexRuntimeNetworkCursor-' + ([BitConverter]::ToString($hash).Replace('-', '').Substring(0, 24))
}

function Invoke-WithCodexRuntimeCursorMutex {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $mutex = [Threading.Mutex]::new($false, (Get-CodexRuntimeCursorMutexName -Path $Path))
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(5))
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) { throw '等待运行期网络日志游标互斥锁超时。' }
        return & $Action
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Read-CodexRuntimeLogCursorCore {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $raw = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ([int]$raw.Version -ne 1) { throw "不支持的运行期网络日志游标版本：$($raw.Version)" }
    $lastLogId = [long]$raw.LastLogId
    if ($lastLogId -lt 0) { throw '运行期网络日志游标不能小于零。' }
    return [pscustomobject]@{
        Version = 1
        LastLogId = $lastLogId
        UpdatedUtc = [string]$raw.UpdatedUtc
    }
}

function Write-CodexRuntimeLogCursorCore {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$LastLogId
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $text = [ordered]@{
        Version = 1
        LastLogId = $LastLogId
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress
    $nonce = [Guid]::NewGuid().ToString('N')
    $tempPath = "$Path.$nonce.tmp"
    $backupPath = "$Path.$nonce.bak"
    try {
        [IO.File]::WriteAllText($tempPath, $text, [Text.UTF8Encoding]::new($false))
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

function ConvertTo-CodexRuntimeNetworkEvent {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][Collections.Generic.HashSet[int]]$ActiveProcessIds,
        [int[]]$ExpectedMaxRetries = @(),
        [switch]$IncludeWebSocket
    )

    if ([string]$Row.ProcessUuid -notmatch '^pid:(?<pid>\d+):') { return $null }
    $processId = [int]$Matches.pid
    if (-not $ActiveProcessIds.Contains($processId)) { return $null }

    $body = [string]$Row.Body
    $maxRetriesMatch = [regex]::Match($body, '\bmax_retries=(?<value>\d+)')
    if (-not $maxRetriesMatch.Success) { return $null }
    $maxRetries = [int]$maxRetriesMatch.Groups['value'].Value
    if ($maxRetries -lt 1 -or $maxRetries -gt 50) { return $null }
    if (@($ExpectedMaxRetries).Count -gt 0 -and $maxRetries -notin @($ExpectedMaxRetries)) { return $null }

    $transport = if ([string]$Row.Transport -in @('WebSocket', 'HttpSse')) {
        [string]$Row.Transport
    }
    elseif ($body -match '(?i)transport="responses_websocket"|stream_responses_websocket|websocket') {
        'WebSocket'
    }
    elseif ($body -match '(?i)transport="responses_http"|stream_responses_api|https?://|error decoding response body') {
        'HttpSse'
    }
    else {
        'Unknown'
    }
    if ($transport -eq 'WebSocket' -and -not $IncludeWebSocket) { return $null }

    $eventClass = $null
    if ($body -match '(?i)error decoding response body') {
        $eventClass = 'ResponseBodyDecode'
    }
    elseif ($body -match '(?i)error sending request(?: for url)?') {
        $eventClass = 'RequestSend'
    }
    elseif ($body -match '(?i)tls handshake eof') {
        $eventClass = 'TlsHandshakeEof'
    }
    elseif ($body -match '(?i)request timed out') {
        $eventClass = 'RequestTimeout'
    }
    elseif ($body -match '(?i)transport error:\s*network error') {
        $eventClass = 'TransportNetwork'
    }
    if ($null -eq $eventClass) { return $null }

    $errorText = if ($body.Contains('sampling_error=')) { $body.Split(@('sampling_error='), 2, [StringSplitOptions]::None)[1] } else { $body }
    if ($errorText.Length -gt 500) { $errorText = $errorText.Substring(0, 500) }
    $retryMatch = [regex]::Match($body, '\bretries=(?<value>\d+)')
    $retry = if ($retryMatch.Success) { [int]$retryMatch.Groups['value'].Value } else { $null }
    $turnMatch = [regex]::Match($body, '\bturn_id=(?<value>[0-9a-f-]+)')
    return [pscustomobject]@{
        LogId = [long]$Row.Id
        TimestampUtc = [DateTimeOffset]::FromUnixTimeSeconds([long]$Row.Timestamp).UtcDateTime
        ProcessId = $processId
        ProcessUuid = [string]$Row.ProcessUuid
        TurnId = if ($turnMatch.Success) { $turnMatch.Groups['value'].Value } else { $null }
        Retry = $retry
        MaxRetries = $maxRetries
        RetriesExhausted = $null -ne $retry -and $retry -ge $maxRetries
        Transport = $transport
        Class = $eventClass
        Error = $errorText
    }
}

function Get-CodexRuntimeNetworkEvents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$CursorPath,
        [int[]]$ActiveProcessIds = @(),
        [int[]]$ExpectedMaxRetries = @(),
        [switch]$IncludeWebSocket,
        [ValidateRange(0, 1000000)][int]$BootstrapRows = 250000,
        [ValidateRange(1000, 2000000)][int]$MaxScanRows = 500000
    )

    if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) {
        return [pscustomobject]@{
            Available = $false
            Error = "Codex 运行日志数据库不存在：$DatabasePath"
            Events = @()
            LastLogId = $null
            Bootstrapped = $false
            CursorRecovered = $false
            ScanTruncated = $false
            RetryRowsScanned = 0
        }
    }

    try {
        Initialize-CodexWinsqliteReader
        return Invoke-WithCodexRuntimeCursorMutex -Path $CursorPath -Action {
            $currentMax = [CodexHotpatch.NetworkLogReaderV1]::GetMaxLogId($DatabasePath)
            $bootstrapped = $false
            $cursorRecovered = $false
            $scanTruncated = $false
            try {
                $cursor = Read-CodexRuntimeLogCursorCore -Path $CursorPath
            }
            catch {
                Write-CodexRuntimeLogCursorCore -Path $CursorPath -LastLogId $currentMax
                return [pscustomobject]@{
                    Available = $true
                    Error = "运行期网络日志游标损坏，已从当前日志末尾安全恢复：$($_.Exception.Message)"
                    Events = @()
                    LastLogId = $currentMax
                    Bootstrapped = $false
                    CursorRecovered = $true
                    ScanTruncated = $false
                    RetryRowsScanned = 0
                }
            }

            if ($null -eq $cursor) {
                $lastLogId = [Math]::Max([long]0, $currentMax - $BootstrapRows)
                $bootstrapped = $true
            }
            elseif ($cursor.LastLogId -gt $currentMax) {
                $lastLogId = [Math]::Max([long]0, $currentMax - $BootstrapRows)
                $cursorRecovered = $true
            }
            else {
                $lastLogId = [long]$cursor.LastLogId
            }

            if (($currentMax - $lastLogId) -gt $MaxScanRows) {
                $lastLogId = $currentMax - $MaxScanRows
                $scanTruncated = $true
            }

            $rows = @([CodexHotpatch.NetworkLogReaderV1]::ReadRetryRows($DatabasePath, $lastLogId, $currentMax))
            $activeSet = [Collections.Generic.HashSet[int]]::new()
            foreach ($activeProcessId in @($ActiveProcessIds)) {
                if ($activeProcessId -gt 0) { [void]$activeSet.Add([int]$activeProcessId) }
            }
            $events = New-Object 'System.Collections.Generic.List[object]'
            foreach ($row in $rows) {
                $event = ConvertTo-CodexRuntimeNetworkEvent -Row $row -ActiveProcessIds $activeSet `
                    -ExpectedMaxRetries $ExpectedMaxRetries -IncludeWebSocket:$IncludeWebSocket
                if ($null -ne $event) { $events.Add($event) }
            }

            # Commit the cursor before exposing a batch. A crash can lose at most the current batch,
            # while it can never replay old user tasks and repeatedly extend a circuit.
            Write-CodexRuntimeLogCursorCore -Path $CursorPath -LastLogId $currentMax
            return [pscustomobject]@{
                Available = $true
                Error = $null
                Events = @($events.ToArray())
                LastLogId = $currentMax
                Bootstrapped = $bootstrapped
                CursorRecovered = $cursorRecovered
                ScanTruncated = $scanTruncated
                RetryRowsScanned = $rows.Count
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Available = $false
            Error = $_.Exception.Message
            Events = @()
            LastLogId = $null
            Bootstrapped = $false
            CursorRecovered = $false
            ScanTruncated = $false
            RetryRowsScanned = 0
        }
    }
}

function Get-CodexRecentRuntimeNetworkEvents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [int[]]$ActiveProcessIds = @(),
        [int[]]$ExpectedMaxRetries = @(),
        [switch]$IncludeWebSocket,
        [TimeSpan]$FailureWindow = ([TimeSpan]::FromMinutes(10)),
        [DateTime]$NowUtc = [DateTime]::UtcNow,
        [ValidateRange(1000, 2000000)][int]$MaxScanRows = 500000
    )

    if ($FailureWindow -le [TimeSpan]::Zero) { throw 'FailureWindow 必须大于零。' }
    if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) {
        return [pscustomobject]@{
            Available = $false
            Error = "Codex 运行日志数据库不存在：$DatabasePath"
            Events = @()
            CurrentMaxLogId = $null
            RetryRowsScanned = 0
            ScanTruncated = $false
        }
    }

    try {
        Initialize-CodexWinsqliteReader
        $currentMax = [CodexHotpatch.NetworkLogReaderV1]::GetMaxLogId($DatabasePath)
        $lowerExclusive = [Math]::Max([long]0, $currentMax - $MaxScanRows)
        $rows = @([CodexHotpatch.NetworkLogReaderV1]::ReadRetryRows($DatabasePath, $lowerExclusive, $currentMax))
        $activeSet = [Collections.Generic.HashSet[int]]::new()
        foreach ($activeProcessId in @($ActiveProcessIds)) {
            if ($activeProcessId -gt 0) { [void]$activeSet.Add([int]$activeProcessId) }
        }

        $now = $NowUtc.ToUniversalTime()
        $windowStart = $now.Subtract($FailureWindow)
        $events = New-Object 'System.Collections.Generic.List[object]'
        foreach ($row in $rows) {
            $event = ConvertTo-CodexRuntimeNetworkEvent -Row $row -ActiveProcessIds $activeSet `
                -ExpectedMaxRetries $ExpectedMaxRetries -IncludeWebSocket:$IncludeWebSocket
            if ($null -ne $event -and $event.TimestampUtc -ge $windowStart -and $event.TimestampUtc -le $now) {
                $events.Add($event)
            }
        }

        return [pscustomobject]@{
            Available = $true
            Error = $null
            Events = @($events.ToArray())
            CurrentMaxLogId = $currentMax
            RetryRowsScanned = $rows.Count
            ScanTruncated = $lowerExclusive -gt 0
        }
    }
    catch {
        return [pscustomobject]@{
            Available = $false
            Error = $_.Exception.Message
            Events = @()
            CurrentMaxLogId = $null
            RetryRowsScanned = 0
            ScanTruncated = $false
        }
    }
}

function Get-CodexRuntimeNetworkDegradation {
    [CmdletBinding()]
    param(
        [object[]]$Events = @(),
        [ValidateRange(2, 20)][int]$FailureThreshold = 3,
        [TimeSpan]$FailureWindow = ([TimeSpan]::FromMinutes(10)),
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    if ($FailureWindow -le [TimeSpan]::Zero) { throw 'FailureWindow 必须大于零。' }
    $now = $NowUtc.ToUniversalTime()
    $windowStart = $now.Subtract($FailureWindow)
    $turnIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $exhaustedTurnIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $recent = New-Object 'System.Collections.Generic.List[object]'
    foreach ($event in @($Events)) {
        if ($null -eq $event -or $null -eq $event.TimestampUtc) { continue }
        $timestamp = ([DateTime]$event.TimestampUtc).ToUniversalTime()
        if ($timestamp -lt $windowStart -or $timestamp -gt $now) { continue }
        $recent.Add($event)
        $key = if (-not [string]::IsNullOrWhiteSpace([string]$event.TurnId)) {
            [string]$event.TurnId
        }
        else {
            "log:$($event.LogId)"
        }
        [void]$turnIds.Add($key)
        $retriesExhaustedProperty = $event.PSObject.Properties['RetriesExhausted']
        if ($null -ne $retriesExhaustedProperty -and $retriesExhaustedProperty.Value -eq $true) {
            [void]$exhaustedTurnIds.Add($key)
        }
    }

    # A single long-running HTTP turn can repeatedly fail without reaching the
    # cross-turn threshold. Require separate retries spanning five minutes;
    # duplicate log rows and short retry bursts must not trigger this path.
    $persistentTurnCount = 0
    $httpEvents = @($recent | Where-Object {
        $_.PSObject.Properties['Transport'] -and $_.Transport -eq 'HttpSse' -and
        $_.PSObject.Properties['ProcessUuid'] -and $_.PSObject.Properties['Retry'] -and
        -not [string]::IsNullOrWhiteSpace([string]$_.TurnId)
    })
    foreach ($group in @($httpEvents | Group-Object ProcessUuid, TurnId)) {
        $ordered = @($group.Group | Sort-Object TimestampUtc, LogId)
        $retryValues = @($ordered | Where-Object { $null -ne $_.Retry } | Select-Object -ExpandProperty Retry -Unique)
        if ($retryValues.Count -ge 2 -and
            (([DateTime]$ordered[-1].TimestampUtc) - ([DateTime]$ordered[0].TimestampUtc)).TotalSeconds -ge 300) {
            $persistentTurnCount++
        }
    }
    $latest = @($recent | Sort-Object TimestampUtc, LogId | Select-Object -Last 1)
    $degraded = $turnIds.Count -ge $FailureThreshold
    return [pscustomobject]@{
        Degraded = $degraded
        FailoverRequired = $degraded -or $exhaustedTurnIds.Count -gt 0 -or $persistentTurnCount -gt 0
        PersistentTurnCount = $persistentTurnCount
        DistinctTurnCount = $turnIds.Count
        ExhaustedTurnCount = $exhaustedTurnIds.Count
        EventCount = $recent.Count
        FailureThreshold = $FailureThreshold
        WindowStartUtc = $windowStart
        TurnIds = @($turnIds | Sort-Object)
        LastFailureUtc = if ($latest.Count -gt 0) { $latest[0].TimestampUtc } else { $null }
        LastFailureReason = if ($latest.Count -gt 0) { $latest[0].Error } else { $null }
    }
}

function Get-CodexRuntimeNetworkCursorStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CursorPath)

    try {
        $cursor = Invoke-WithCodexRuntimeCursorMutex -Path $CursorPath -Action {
            Read-CodexRuntimeLogCursorCore -Path $CursorPath
        }
        return [pscustomobject]@{
            Exists = $null -ne $cursor
            Healthy = $true
            LastLogId = if ($null -ne $cursor) { $cursor.LastLogId } else { $null }
            UpdatedUtc = if ($null -ne $cursor) { $cursor.UpdatedUtc } else { $null }
            Error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Exists = Test-Path -LiteralPath $CursorPath -PathType Leaf
            Healthy = $false
            LastLogId = $null
            UpdatedUtc = $null
            Error = $_.Exception.Message
        }
    }
}

Export-ModuleMember -Function Get-CodexRuntimeNetworkEvents, Get-CodexRecentRuntimeNetworkEvents, `
    Get-CodexRuntimeNetworkDegradation, Get-CodexRuntimeNetworkCursorStatus
