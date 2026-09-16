import assert from 'node:assert/strict';
import test from 'node:test';

import {
  loadArchivedThreadIndex,
  normalizeArchivedThreadRows,
  normalizeThreadIds,
  normalizeTimestampMs,
} from './archived-thread-index.mjs';

test('normalizes milliseconds first and falls back from seconds', () => {
  assert.equal(normalizeTimestampMs(1_785_122_473_548, 1_785_122_473), 1_785_122_473_548);
  assert.equal(normalizeTimestampMs(null, 1_785_122_473), 1_785_122_473_000);
  assert.equal(normalizeTimestampMs(0, 0), 0);
});

test('normalizes and deduplicates archived thread rows', () => {
  const rows = normalizeArchivedThreadRows([
    {
      id: '019fa197-464c-7031-8fd2-c01eab763a27',
      createdAt: 1_785_122_473,
      updatedAtMs: 1_785_122_492_602,
      recencyAtMs: 1_785_122_474_351,
    },
    { id: '019FA197-464C-7031-8FD2-C01EAB763A27' },
    { id: 'not-a-thread-id' },
  ]);
  assert.deepEqual(rows, [{
    id: '019fa197-464c-7031-8fd2-c01eab763a27',
    createdAt: 1_785_122_473_000,
    updatedAt: 1_785_122_492_602,
    recencyAt: 1_785_122_474_351,
  }]);
});

test('normalizes the complete local thread ID inventory', () => {
  assert.deepEqual(normalizeThreadIds([
    { id: '019fa197-464c-7031-8fd2-c01eab763a27' },
    { id: '019FA197-464C-7031-8FD2-C01EAB763A27' },
    { id: '019fa197-464c-7031-8fd2-c01eab763a28' },
    { id: 'not-a-thread-id' },
  ]), [
    '019fa197-464c-7031-8fd2-c01eab763a27',
    '019fa197-464c-7031-8fd2-c01eab763a28',
  ]);
});

test('opens the Codex index read-only and selects archived rows only', async () => {
  const calls = { options: null, exec: [], queries: [] };
  class FixtureDatabase {
    constructor(databasePath, options) {
      assert.equal(databasePath, 'fixture.sqlite');
      calls.options = options;
    }

    exec(statement) {
      calls.exec.push(statement);
    }

    prepare(statement) {
      if (statement === 'PRAGMA table_info(threads)') {
        return {
          all: () => [
            'id', 'archived', 'created_at', 'created_at_ms', 'updated_at',
            'updated_at_ms', 'recency_at', 'recency_at_ms',
          ].map((name) => ({ name })),
        };
      }
      calls.queries.push(statement);
      if (statement === 'SELECT id FROM threads') {
        return {
          all: () => [
            { id: '019fa197-464c-7031-8fd2-c01eab763a27' },
            { id: '019fa197-464c-7031-8fd2-c01eab763a28' },
          ],
        };
      }
      return {
        all: () => [{
          id: '019fa197-464c-7031-8fd2-c01eab763a27',
          createdAt: 1_785_122_473,
          createdAtMs: 1_785_122_473_548,
          updatedAt: 1_785_122_492,
          updatedAtMs: 1_785_122_492_602,
          recencyAt: 1_785_122_474,
          recencyAtMs: 1_785_122_474_351,
        }],
      };
    }

    close() {
      calls.closed = true;
    }
  }

  const result = await loadArchivedThreadIndex('fixture.sqlite', {
    DatabaseSyncImpl: FixtureDatabase,
  });
  assert.equal(result.loaded, true);
  assert.equal(result.threads.length, 1);
  assert.deepEqual(result.knownThreadIds, [
    '019fa197-464c-7031-8fd2-c01eab763a27',
    '019fa197-464c-7031-8fd2-c01eab763a28',
  ]);
  assert.deepEqual(calls.options, { readOnly: true, timeout: 500 });
  assert.deepEqual(calls.exec, ['PRAGMA query_only = ON']);
  assert.match(calls.queries[0], /WHERE archived = 1/);
  assert.equal(calls.queries[1], 'SELECT id FROM threads');
  assert.equal(calls.closed, true);
});

test('degrades to an empty seed when the read-only database is unavailable', async () => {
  class FailingDatabase {
    constructor() {
      const error = new Error('database unavailable');
      error.code = 'SQLITE_CANTOPEN';
      throw error;
    }
  }
  const result = await loadArchivedThreadIndex('missing.sqlite', {
    DatabaseSyncImpl: FailingDatabase,
  });
  assert.deepEqual(result, {
    loaded: false,
    source: 'state_5.sqlite-read-only',
    threads: [],
    knownThreadIds: [],
    error: 'SQLITE_CANTOPEN',
  });
});
