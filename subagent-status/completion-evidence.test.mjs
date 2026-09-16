import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  createCompletionEvidenceIndex,
  readAgentMetadata,
  readLatestLifecycle,
  threadIdFromRolloutPath,
} from './completion-evidence.mjs';

const id = '019fb298-f321-7f61-bf5d-6f67729496ff';
const archivedId = '019fb298-f321-7f61-bf5d-6f6772949700';
const parentId = '019fb2f4-a18e-74c0-93d0-cafc91b0d28f';

async function withRollout(lines, callback) {
  const root = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'codex-evidence-'));
  const filePath = path.join(root, `rollout-test-${id}.jsonl`);
  try {
    await fs.promises.writeFile(filePath, `${lines.join('\n')}\n`, 'utf8');
    await callback(filePath);
  } finally {
    await fs.promises.rm(root, { recursive: true, force: true });
  }
}

const event = (type) => JSON.stringify({
  timestamp: new Date().toISOString(),
  type: 'event_msg',
  payload: { type },
});

test('extracts an exact conversation id from a rollout filename', () => {
  assert.equal(threadIdFromRolloutPath(`rollout-test-${id}.jsonl`), id);
  assert.equal(threadIdFromRolloutPath('rollout-without-id.jsonl'), null);
});

test('accepts task_complete only when it is the latest lifecycle event', async () => {
  await withRollout([event('task_started'), event('task_complete')], async (filePath) => {
    assert.equal((await readLatestLifecycle(filePath)).state, 'complete');
  });
});

test('rejects a completed prior turn after a follow-up task_started event', async () => {
  await withRollout([event('task_started'), event('task_complete'), event('task_started')], async (filePath) => {
    assert.equal((await readLatestLifecycle(filePath)).state, 'active');
  });
});

test('does not trust task_complete text nested inside another record', async () => {
  await withRollout([
    event('task_started'),
    JSON.stringify({ type: 'response_item', payload: { message: '"type":"task_complete"' } }),
  ], async (filePath) => {
    assert.equal((await readLatestLifecycle(filePath)).state, 'active');
  });
});

test('fails closed while the last JSONL record is incomplete', async () => {
  const root = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'codex-evidence-'));
  const filePath = path.join(root, `rollout-test-${id}.jsonl`);
  try {
    await fs.promises.writeFile(filePath, `${event('task_complete')}\n{"type":"event_msg"`, 'utf8');
    assert.equal((await readLatestLifecycle(filePath)).state, 'unknown');
  } finally {
    await fs.promises.rm(root, { recursive: true, force: true });
  }
});

test('fails closed when a newer complete line is malformed JSON', async () => {
  await withRollout([
    event('task_complete'),
    '{"type":"event_msg","payload":',
  ], async (filePath) => {
    const evidence = await readLatestLifecycle(filePath);
    assert.deepEqual(evidence, { state: 'unknown', reason: 'invalid-json' });
  });
});

test('removes stale completion evidence when a follow-up starts and restores it after completion', async () => {
  const root = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'codex-evidence-'));
  const filePath = path.join(root, `rollout-test-${id}.jsonl`);
  let index;
  const waitFor = async (predicate, timeoutMs = 4000) => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (predicate()) return;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    assert.fail('timed out waiting for evidence index update');
  };
  try {
    await fs.promises.writeFile(filePath, `${event('task_started')}\n${event('task_complete')}\n`, 'utf8');
    index = await createCompletionEvidenceIndex(root);
    assert.equal(index.snapshot().ids.includes(id), true);

    await fs.promises.appendFile(filePath, `${event('task_started')}\n`, 'utf8');
    await waitFor(() => !index.snapshot().ids.includes(id));
    assert.equal(index.snapshot().ids.includes(id), false);

    await fs.promises.appendFile(filePath, `${event('task_complete')}\n`, 'utf8');
    await waitFor(() => index.snapshot().ids.includes(id));
    assert.equal(index.snapshot().ids.includes(id), true);
  } finally {
    await index?.close();
    await fs.promises.rm(root, { recursive: true, force: true });
  }
});

test('canonicalizes watcher roots before passing Windows short-path aliases to libuv', async (t) => {
  const root = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'codex-evidence-'));
  const observedRoots = [];
  const watch = fs.watch;
  const mock = t.mock.method(fs, 'watch', (directory, ...args) => {
    observedRoots.push(directory);
    return watch(directory, ...args);
  });
  let index;
  try {
    index = await createCompletionEvidenceIndex(root);
    assert.equal(index.watching, true);
    assert.deepEqual(observedRoots, [fs.realpathSync.native(root)]);
  } finally {
    await index?.close();
    mock.mock.restore();
    await fs.promises.rm(root, { recursive: true, force: true });
  }
});

test('rebuilds completion evidence from the rollout after an index process restart', async () => {
  const root = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'codex-evidence-'));
  const filePath = path.join(root, `rollout-test-${id}.jsonl`);
  let firstIndex;
  let restartedIndex;
  try {
    await fs.promises.writeFile(filePath, `${event('task_started')}\n${event('task_complete')}\n`, 'utf8');
    firstIndex = await createCompletionEvidenceIndex(root);
    assert.equal(firstIndex.snapshot().ids.includes(id), true);
    await firstIndex.close();
    firstIndex = null;

    restartedIndex = await createCompletionEvidenceIndex(root);
    assert.equal(restartedIndex.snapshot().ids.includes(id), true);
  } finally {
    await firstIndex?.close();
    await restartedIndex?.close();
    await fs.promises.rm(root, { recursive: true, force: true });
  }
});

test('rebuilds completion evidence from archived rollouts after restart', async () => {
  const root = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'codex-evidence-roots-'));
  const sessionsRoot = path.join(root, 'sessions');
  const archivedRoot = path.join(root, 'archived_sessions');
  let index;
  try {
    await fs.promises.mkdir(sessionsRoot);
    await fs.promises.mkdir(archivedRoot);
    await fs.promises.writeFile(
      path.join(archivedRoot, `rollout-test-${archivedId}.jsonl`),
      `${event('task_started')}\n${event('task_complete')}\n`,
      'utf8',
    );

    index = await createCompletionEvidenceIndex([sessionsRoot, archivedRoot]);
    assert.equal(index.snapshot().ids.includes(archivedId), true);
  } finally {
    await index?.close();
    await fs.promises.rm(root, { recursive: true, force: true });
  }
});

test('prefers a current sessions rollout over stale archived completion evidence', async () => {
  const root = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'codex-evidence-roots-'));
  const sessionsRoot = path.join(root, 'sessions');
  const archivedRoot = path.join(root, 'archived_sessions');
  let index;
  try {
    await fs.promises.mkdir(sessionsRoot);
    await fs.promises.mkdir(archivedRoot);
    await fs.promises.writeFile(
      path.join(archivedRoot, `rollout-test-${archivedId}.jsonl`),
      `${event('task_started')}\n${event('task_complete')}\n`,
      'utf8',
    );
    await fs.promises.writeFile(
      path.join(sessionsRoot, `rollout-test-${archivedId}.jsonl`),
      `${event('task_started')}\n`,
      'utf8',
    );

    index = await createCompletionEvidenceIndex([sessionsRoot, archivedRoot]);
    assert.equal(index.snapshot().ids.includes(archivedId), false);
  } finally {
    await index?.close();
    await fs.promises.rm(root, { recursive: true, force: true });
  }
});

test('keeps confirmed archived completion after Codex removes the rollout and the index restarts', async () => {
  const root = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'codex-evidence-cache-'));
  const sessionsRoot = path.join(root, 'sessions');
  const archivedRoot = path.join(root, 'archived_sessions');
  const cachePath = path.join(root, 'completion-evidence-cache.json');
  const archivedPath = path.join(archivedRoot, `rollout-test-${archivedId}.jsonl`);
  let firstIndex;
  let restartedIndex;
  try {
    await fs.promises.mkdir(sessionsRoot);
    await fs.promises.mkdir(archivedRoot);
    await fs.promises.writeFile(
      archivedPath,
      `${event('task_started')}\n${event('task_complete')}\n`,
      'utf8',
    );

    firstIndex = await createCompletionEvidenceIndex(
      [sessionsRoot, archivedRoot],
      () => {},
      { cachePath },
    );
    assert.equal(firstIndex.snapshot().ids.includes(archivedId), true);
    await firstIndex.close();
    firstIndex = null;
    assert.deepEqual(JSON.parse(await fs.promises.readFile(cachePath, 'utf8')), [archivedId]);

    await fs.promises.unlink(archivedPath);
    restartedIndex = await createCompletionEvidenceIndex(
      [sessionsRoot, archivedRoot],
      () => {},
      { cachePath },
    );
    assert.equal(restartedIndex.snapshot().ids.includes(archivedId), true);
    assert.equal(restartedIndex.snapshot().cacheItems, 1);
  } finally {
    await firstIndex?.close();
    await restartedIndex?.close();
    await fs.promises.rm(root, { recursive: true, force: true });
  }
});

test('a later active task_started rollout revokes durable completion evidence', async () => {
  const root = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'codex-evidence-cache-'));
  const sessionsRoot = path.join(root, 'sessions');
  const archivedRoot = path.join(root, 'archived_sessions');
  const cachePath = path.join(root, 'completion-evidence-cache.json');
  let index;
  try {
    await fs.promises.mkdir(sessionsRoot);
    await fs.promises.mkdir(archivedRoot);
    await fs.promises.writeFile(cachePath, `${JSON.stringify([archivedId])}\n`, 'utf8');
    await fs.promises.writeFile(
      path.join(sessionsRoot, `rollout-test-${archivedId}.jsonl`),
      `${event('task_started')}\n`,
      'utf8',
    );

    index = await createCompletionEvidenceIndex(
      [sessionsRoot, archivedRoot],
      () => {},
      { cachePath },
    );
    assert.equal(index.snapshot().ids.includes(archivedId), false);
    assert.deepEqual(JSON.parse(await fs.promises.readFile(cachePath, 'utf8')), []);
  } finally {
    await index?.close();
    await fs.promises.rm(root, { recursive: true, force: true });
  }
});

test('ignores a damaged durable cache without inventing completion evidence', async () => {
  const root = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'codex-evidence-cache-'));
  const sessionsRoot = path.join(root, 'sessions');
  const archivedRoot = path.join(root, 'archived_sessions');
  const cachePath = path.join(root, 'completion-evidence-cache.json');
  let index;
  try {
    await fs.promises.mkdir(sessionsRoot);
    await fs.promises.mkdir(archivedRoot);
    await fs.promises.writeFile(cachePath, `[\"${archivedId}\"`, 'utf8');

    index = await createCompletionEvidenceIndex(
      [sessionsRoot, archivedRoot],
      () => {},
      { cachePath },
    );
    assert.deepEqual(index.snapshot().ids, []);
    assert.notEqual(index.snapshot().cacheError, null);
  } finally {
    await index?.close();
    await fs.promises.rm(root, { recursive: true, force: true });
  }
});

test('joins completed rollout evidence to read-only spawn metadata for renderer fallback', async () => {
  const root = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'codex-agent-metadata-'));
  const sessionsRoot = path.join(root, 'sessions');
  const databasePath = path.join(root, 'state_5.sqlite');
  const completedId = '019ffab3-c0c8-7cf1-941d-a990597e4cb5';
  const activeId = '019ffaa8-7f15-7882-a012-2bae6e308078';
  let index;
  try {
    await fs.promises.mkdir(sessionsRoot);
    await fs.promises.writeFile(
      path.join(sessionsRoot, `rollout-test-${completedId}.jsonl`),
      `${event('task_started')}\n${event('task_complete')}\n`,
      'utf8',
    );
    await fs.promises.writeFile(
      path.join(sessionsRoot, `rollout-test-${activeId}.jsonl`),
      `${event('task_started')}\n`,
      'utf8',
    );

    const { DatabaseSync } = await import('node:sqlite');
    const database = new DatabaseSync(databasePath);
    try {
      database.exec(`
        CREATE TABLE threads (
          id TEXT PRIMARY KEY,
          agent_path TEXT,
          agent_nickname TEXT
        );
        CREATE TABLE thread_spawn_edges (
          parent_thread_id TEXT NOT NULL,
          child_thread_id TEXT NOT NULL PRIMARY KEY,
          status TEXT NOT NULL
        );
      `);
      const insertThread = database.prepare(
        'INSERT INTO threads (id, agent_path, agent_nickname) VALUES (?, ?, ?)',
      );
      const insertEdge = database.prepare(
        'INSERT INTO thread_spawn_edges (parent_thread_id, child_thread_id, status) VALUES (?, ?, ?)',
      );
      insertThread.run(completedId, '/root/space_skill_forward_eval', 'Schrodinger');
      insertThread.run(activeId, '/root/storage_system_benchmark', 'Tesla');
      insertEdge.run(parentId, completedId, 'open');
      insertEdge.run(parentId, activeId, 'open');
    } finally {
      database.close();
    }

    const metadata = await readAgentMetadata(databasePath);
    assert.equal(metadata.error, null);
    assert.equal(metadata.records.length, 2);

    index = await createCompletionEvidenceIndex(
      sessionsRoot,
      () => {},
      { agentMetadataDatabasePath: databasePath },
    );
    assert.deepEqual(index.snapshot().agents, [{
      conversationId: completedId,
      parentConversationId: parentId,
      agentPath: '/root/space_skill_forward_eval',
      agentNickname: 'Schrodinger',
    }]);
    assert.equal(index.snapshot().agentMetadataItems, 2);
    assert.equal(index.snapshot().agentMetadataError, null);
  } finally {
    await index?.close();
    await fs.promises.rm(root, { recursive: true, force: true });
  }
});
