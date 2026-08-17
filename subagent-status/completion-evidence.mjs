import fs from 'node:fs';
import path from 'node:path';

const THREAD_ID_PATTERN = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i;
const INITIAL_TAIL_BYTES = 64 * 1024;
const MAX_TAIL_BYTES = 2 * 1024 * 1024;

export function threadIdFromRolloutPath(filePath) {
  return path.basename(filePath).match(THREAD_ID_PATTERN)?.[1]?.toLowerCase() || null;
}

export async function readLatestLifecycle(filePath, maxTailBytes = MAX_TAIL_BYTES) {
  let handle;
  try {
    handle = await fs.promises.open(filePath, 'r');
    const before = await handle.stat();
    if (!before.isFile() || before.size < 1) return { state: 'unknown', reason: 'empty' };

    let readBytes = Math.min(INITIAL_TAIL_BYTES, before.size, maxTailBytes);
    let result = { state: 'unknown', reason: 'lifecycle-not-in-tail' };

    while (readBytes > 0) {
      const start = Math.max(0, before.size - readBytes);
      const buffer = Buffer.alloc(before.size - start);
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, start);
      let text = buffer.subarray(0, bytesRead).toString('utf8');

      if (!text.endsWith('\n')) return { state: 'unknown', reason: 'partial-write' };
      if (start > 0) {
        const firstNewline = text.indexOf('\n');
        if (firstNewline < 0) {
          if (readBytes >= Math.min(before.size, maxTailBytes)) break;
          readBytes = Math.min(readBytes * 2, before.size, maxTailBytes);
          continue;
        }
        text = text.slice(firstNewline + 1);
      }

      const lines = text.split('\n');
      for (let index = lines.length - 1; index >= 0; index -= 1) {
        if (!lines[index].trim()) continue;
        let record;
        try {
          record = JSON.parse(lines[index]);
        } catch {
          return { state: 'unknown', reason: 'invalid-json' };
        }
        if (record?.type !== 'event_msg') continue;
        const lifecycle = record?.payload?.type;
        if (lifecycle === 'task_complete') {
          result = { state: 'complete', reason: 'latest-lifecycle-task-complete' };
          break;
        }
        if (lifecycle === 'task_started') {
          result = { state: 'active', reason: 'latest-lifecycle-task-started' };
          break;
        }
      }

      if (result.state !== 'unknown' || start === 0 || readBytes >= maxTailBytes) break;
      readBytes = Math.min(readBytes * 2, before.size, maxTailBytes);
    }

    const after = await handle.stat();
    if (after.size !== before.size || after.mtimeMs !== before.mtimeMs) {
      return { state: 'unknown', reason: 'changed-during-read' };
    }
    return result;
  } catch (error) {
    return { state: 'unknown', reason: error?.code || error?.message || 'read-failed' };
  } finally {
    await handle?.close().catch(() => {});
  }
}

async function discoverRolloutFiles(root) {
  const files = [];
  const pending = [root];
  while (pending.length) {
    const directory = pending.pop();
    let entries;
    try {
      entries = await fs.promises.readdir(directory, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const fullPath = path.join(directory, entry.name);
      if (entry.isDirectory()) pending.push(fullPath);
      else if (entry.isFile() && THREAD_ID_PATTERN.test(entry.name)) files.push(fullPath);
    }
  }
  return files;
}

async function mapInBatches(values, batchSize, callback) {
  for (let index = 0; index < values.length; index += batchSize) {
    await Promise.all(values.slice(index, index + batchSize).map(callback));
  }
}

export async function createCompletionEvidenceIndex(root, onChange = () => {}) {
  const completed = new Set();
  const filesById = new Map();
  const timers = new Map();
  let revision = 1;
  let closed = false;
  let watcher = null;

  function snapshot() {
    return {
      ids: [...completed].sort(),
      revision,
      updatedAt: Date.now(),
      source: 'latest-rollout-lifecycle',
    };
  }

  function emit(reason) {
    if (closed) return;
    revision += 1;
    onChange(snapshot(), reason);
  }

  async function inspect(threadId, filePath, reason) {
    const evidence = await readLatestLifecycle(filePath);
    if (closed || filesById.get(threadId) !== filePath) return;
    const wasComplete = completed.has(threadId);
    const isComplete = evidence.state === 'complete';
    if (isComplete) completed.add(threadId);
    else completed.delete(threadId);
    if (wasComplete !== isComplete) emit(reason);
  }

  const files = await discoverRolloutFiles(root);
  for (const filePath of files) {
    const threadId = threadIdFromRolloutPath(filePath);
    if (threadId) filesById.set(threadId, filePath);
  }
  await mapInBatches([...filesById], 16, async ([threadId, filePath]) => {
    const evidence = await readLatestLifecycle(filePath);
    if (evidence.state === 'complete') completed.add(threadId);
  });

  try {
    watcher = fs.watch(root, { recursive: true }, (_eventType, filename) => {
      if (closed || !filename) return;
      const relativePath = filename.toString();
      const threadId = threadIdFromRolloutPath(relativePath);
      if (!threadId) return;
      const filePath = path.resolve(root, relativePath);
      filesById.set(threadId, filePath);

      if (completed.delete(threadId)) emit('rollout-changed-fail-closed');
      const existing = timers.get(threadId);
      if (existing) clearTimeout(existing);
      const timer = setTimeout(() => {
        timers.delete(threadId);
        void inspect(threadId, filePath, 'rollout-lifecycle-updated');
      }, 1000);
      timers.set(threadId, timer);
    });
  } catch {
    watcher = null;
  }

  return {
    snapshot,
    watching: Boolean(watcher),
    async close() {
      closed = true;
      watcher?.close();
      for (const timer of timers.values()) clearTimeout(timer);
      timers.clear();
    },
  };
}
