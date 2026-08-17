import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  createCompletionEvidenceIndex,
  readLatestLifecycle,
  threadIdFromRolloutPath,
} from './completion-evidence.mjs';

const id = '019fb298-f321-7f61-bf5d-6f67729496ff';

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
