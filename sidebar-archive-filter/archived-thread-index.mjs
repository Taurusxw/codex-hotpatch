import os from 'node:os';
import path from 'node:path';

const THREAD_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SECOND_TIMESTAMP_CEILING = 100_000_000_000;

export function normalizeTimestampMs(preferredMilliseconds, fallbackSeconds) {
  for (const candidate of [preferredMilliseconds, fallbackSeconds]) {
    const value = Number(candidate);
    if (!Number.isFinite(value) || value <= 0) continue;
    return Math.trunc(value < SECOND_TIMESTAMP_CEILING ? value * 1000 : value);
  }
  return 0;
}

export function normalizeArchivedThreadRows(rows) {
  const threads = [];
  const seen = new Set();
  for (const row of Array.isArray(rows) ? rows : []) {
    const id = String(row?.id || '').toLowerCase();
    if (!THREAD_ID_PATTERN.test(id) || seen.has(id)) continue;
    seen.add(id);
    const createdAt = normalizeTimestampMs(row.createdAtMs, row.createdAt);
    const updatedAt = normalizeTimestampMs(row.updatedAtMs, row.updatedAt) || createdAt;
    const recencyAt = normalizeTimestampMs(row.recencyAtMs, row.recencyAt) || updatedAt || createdAt;
    threads.push({ id, createdAt, updatedAt, recencyAt });
  }
  threads.sort((left, right) => left.id.localeCompare(right.id));
  return threads;
}

export function normalizeThreadIds(rows) {
  const ids = new Set();
  for (const row of Array.isArray(rows) ? rows : []) {
    const id = String(row?.id || '').toLowerCase();
    if (THREAD_ID_PATTERN.test(id)) ids.add(id);
  }
  return [...ids].sort((left, right) => left.localeCompare(right));
}

export function defaultCodexStateDatabasePath() {
  const codexRoot = process.env.CODEX_HOME
    ? path.resolve(process.env.CODEX_HOME)
    : path.join(os.homedir(), '.codex');
  return path.join(codexRoot, 'state_5.sqlite');
}

function selectedColumn(columns, name, alias) {
  return columns.has(name) ? `${name} AS ${alias}` : `NULL AS ${alias}`;
}

export async function loadArchivedThreadIndex(
  databasePath = defaultCodexStateDatabasePath(),
  options = {},
) {
  let database;
  try {
    const DatabaseSyncImpl = options.DatabaseSyncImpl
      || (await import('node:sqlite')).DatabaseSync;
    database = new DatabaseSyncImpl(databasePath, {
      readOnly: true,
      timeout: 500,
    });
    database.exec?.('PRAGMA query_only = ON');
    const columns = new Set(
      database.prepare('PRAGMA table_info(threads)').all()
        .map((column) => String(column?.name || '')),
    );
    if (!columns.has('id') || !columns.has('archived')) {
      throw new Error('threads archive columns are unavailable');
    }
    const selectColumns = [
      'id',
      selectedColumn(columns, 'created_at_ms', 'createdAtMs'),
      selectedColumn(columns, 'created_at', 'createdAt'),
      selectedColumn(columns, 'updated_at_ms', 'updatedAtMs'),
      selectedColumn(columns, 'updated_at', 'updatedAt'),
      selectedColumn(columns, 'recency_at_ms', 'recencyAtMs'),
      selectedColumn(columns, 'recency_at', 'recencyAt'),
    ];
    const archivedRows = database.prepare(`
      SELECT ${selectColumns.join(', ')}
      FROM threads
      WHERE archived = 1
    `).all();
    const knownThreadRows = database.prepare('SELECT id FROM threads').all();
    return {
      loaded: true,
      source: 'state_5.sqlite-read-only',
      threads: normalizeArchivedThreadRows(archivedRows),
      knownThreadIds: normalizeThreadIds(knownThreadRows),
      error: '',
    };
  } catch (error) {
    return {
      loaded: false,
      source: 'state_5.sqlite-read-only',
      threads: [],
      knownThreadIds: [],
      error: error?.code || error?.message || 'archive-index-read-failed',
    };
  } finally {
    database?.close?.();
  }
}
