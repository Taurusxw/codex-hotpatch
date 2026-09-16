import fs from 'node:fs';
import path from 'node:path';

const THREAD_ID_PATTERN = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i;
const THREAD_ID_ONLY_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const INITIAL_TAIL_BYTES = 64 * 1024;
const MAX_TAIL_BYTES = 2 * 1024 * 1024;

export async function readAgentMetadata(databasePath) {
  if (!databasePath) return { records: [], error: null };
  let database;
  try {
    const { DatabaseSync } = await import('node:sqlite');
    database = new DatabaseSync(databasePath, {
      readOnly: true,
      timeout: 500,
    });
    const rows = database.prepare(`
      SELECT
        edge.parent_thread_id AS parentConversationId,
        edge.child_thread_id AS conversationId,
        thread.agent_path AS agentPath,
        thread.agent_nickname AS agentNickname
      FROM thread_spawn_edges AS edge
      JOIN threads AS thread ON thread.id = edge.child_thread_id
      WHERE thread.agent_path IS NOT NULL OR thread.agent_nickname IS NOT NULL
    `).all();
    const records = [];
    for (const row of rows) {
      const conversationId = String(row.conversationId || '').toLowerCase();
      const parentConversationId = String(row.parentConversationId || '').toLowerCase();
      if (!THREAD_ID_ONLY_PATTERN.test(conversationId)
          || !THREAD_ID_ONLY_PATTERN.test(parentConversationId)) {
        continue;
      }
      records.push({
        conversationId,
        parentConversationId,
        agentPath: typeof row.agentPath === 'string' ? row.agentPath : '',
        agentNickname: typeof row.agentNickname === 'string' ? row.agentNickname : '',
      });
    }
    records.sort((left, right) => left.conversationId.localeCompare(right.conversationId));
    return { records, error: null };
  } catch (error) {
    return { records: [], error: error?.code || error?.message || 'metadata-read-failed' };
  } finally {
    database?.close();
  }
}

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

function normalizeRoots(rootOrRoots) {
  const roots = Array.isArray(rootOrRoots) ? rootOrRoots : [rootOrRoots];
  return [...new Set(roots.filter(Boolean).map((root) => {
    const resolved = path.resolve(root);
    try {
      // libuv's Windows watcher can abort on 8.3 aliases (such as ADMINI~1).
      // Discovery and watch events must use the same canonical directory spelling.
      return fs.realpathSync.native(resolved);
    } catch {
      return resolved; // Optional roots may not exist yet.
    }
  }))];
}

async function loadCompletionCache(cachePath) {
  if (!cachePath) return { ids: new Set(), error: null };
  try {
    const parsed = JSON.parse(await fs.promises.readFile(cachePath, 'utf8'));
    if (!Array.isArray(parsed) || parsed.some((value) => typeof value !== 'string')) {
      return { ids: new Set(), error: 'invalid-shape' };
    }
    const ids = new Set();
    for (const value of parsed) {
      const normalized = value.toLowerCase();
      if (!THREAD_ID_ONLY_PATTERN.test(normalized)) return { ids: new Set(), error: 'invalid-id' };
      ids.add(normalized);
    }
    return { ids, error: null };
  } catch (error) {
    if (error?.code === 'ENOENT') return { ids: new Set(), error: null };
    return { ids: new Set(), error: error?.code || 'read-failed' };
  }
}

async function writeCompletionCache(cachePath, ids) {
  if (!cachePath) return;
  await fs.promises.mkdir(path.dirname(cachePath), { recursive: true });
  const temporaryPath = `${cachePath}.${process.pid}.${Date.now()}.tmp`;
  try {
    await fs.promises.writeFile(temporaryPath, `${JSON.stringify([...ids].sort())}\n`, 'utf8');
    await fs.promises.rename(temporaryPath, cachePath);
  } catch (error) {
    await fs.promises.unlink(temporaryPath).catch(() => {});
    throw error;
  }
}

export async function createCompletionEvidenceIndex(
  rootOrRoots,
  onChange = () => {},
  options = {},
) {
  const roots = normalizeRoots(rootOrRoots);
  const cachePath = options.cachePath ? path.resolve(options.cachePath) : null;
  const agentMetadataDatabasePath = options.agentMetadataDatabasePath
    ? path.resolve(options.agentMetadataDatabasePath)
    : null;
  const agentMetadataRefreshMs = Math.max(1000, options.agentMetadataRefreshMs || 5000);
  const agentMetadataLoader = options.agentMetadataLoader || readAgentMetadata;
  const loadedCache = await loadCompletionCache(cachePath);
  const cachedCompleted = loadedCache.ids;
  const completed = new Set(cachedCompleted);
  const filesById = new Map();
  const candidatesById = new Map();
  const timers = new Map();
  let revision = 1;
  let closed = false;
  let cacheError = loadedCache.error;
  let cacheWriteQueue = Promise.resolve();
  let agentMetadata = new Map();
  let agentMetadataError = null;
  let agentMetadataTimer = null;
  let agentMetadataRefresh = null;
  const watchers = [];

  function snapshot() {
    const ids = [...completed].sort();
    return {
      ids,
      agents: ids.map((id) => agentMetadata.get(id)).filter(Boolean),
      revision,
      updatedAt: Date.now(),
      source: 'latest-rollout-lifecycle-durable-cache-and-readonly-agent-metadata',
      cacheEnabled: Boolean(cachePath),
      cacheItems: cachedCompleted.size,
      cacheError,
      agentMetadataEnabled: Boolean(agentMetadataDatabasePath),
      agentMetadataItems: agentMetadata.size,
      agentMetadataError,
    };
  }

  function emit(reason) {
    if (closed) return;
    revision += 1;
    onChange(snapshot(), reason);
  }

  function queueCacheWrite() {
    if (!cachePath) return cacheWriteQueue;
    const ids = new Set(cachedCompleted);
    cacheWriteQueue = cacheWriteQueue.then(async () => {
      try {
        await writeCompletionCache(cachePath, ids);
        cacheError = null;
      } catch (error) {
        cacheError = error?.code || 'write-failed';
      }
    });
    return cacheWriteQueue;
  }

  async function refreshAgentMetadata(reason, notify = true) {
    if (!agentMetadataDatabasePath || closed) return;
    if (agentMetadataRefresh) return agentMetadataRefresh;
    agentMetadataRefresh = (async () => {
      const loaded = await agentMetadataLoader(agentMetadataDatabasePath);
      if (closed) return;
      const previousError = agentMetadataError;
      let changed = false;
      if (!loaded.error) {
        const nextMetadata = new Map();
        for (const record of loaded.records || []) {
          const id = record?.conversationId?.toLowerCase?.() || '';
          const parentId = record?.parentConversationId?.toLowerCase?.() || '';
          if (!THREAD_ID_ONLY_PATTERN.test(id) || !THREAD_ID_ONLY_PATTERN.test(parentId)) continue;
          nextMetadata.set(id, {
            conversationId: id,
            parentConversationId: parentId,
            agentPath: typeof record.agentPath === 'string' ? record.agentPath : '',
            agentNickname: typeof record.agentNickname === 'string' ? record.agentNickname : '',
          });
        }
        changed = nextMetadata.size !== agentMetadata.size;
        if (!changed) {
          for (const [id, record] of nextMetadata) {
            const previous = agentMetadata.get(id);
            if (!previous
                || previous.parentConversationId !== record.parentConversationId
                || previous.agentPath !== record.agentPath
                || previous.agentNickname !== record.agentNickname) {
              changed = true;
              break;
            }
          }
        }
        agentMetadata = nextMetadata;
      }
      agentMetadataError = loaded.error || null;
      if (notify && (changed || previousError !== agentMetadataError)) emit(reason);
    })();
    try {
      await agentMetadataRefresh;
    } finally {
      agentMetadataRefresh = null;
    }
  }

  function applyEvidence(threadId, evidence, priority, reason, persist = true) {
    const wasComplete = completed.has(threadId);
    const wasCached = cachedCompleted.has(threadId);

    if (evidence.state === 'complete') {
      completed.add(threadId);
      cachedCompleted.add(threadId);
    } else if (evidence.state === 'active' || priority === 0) {
      completed.delete(threadId);
      cachedCompleted.delete(threadId);
    } else if (cachedCompleted.has(threadId)) {
      completed.add(threadId);
    } else {
      completed.delete(threadId);
    }

    if (persist && wasCached !== cachedCompleted.has(threadId)) queueCacheWrite();
    if (wasComplete !== completed.has(threadId)) emit(reason);
    return wasCached !== cachedCompleted.has(threadId);
  }

  async function inspect(threadId, selected, reason) {
    const evidence = await readLatestLifecycle(selected.filePath);
    if (closed || filesById.get(threadId)?.filePath !== selected.filePath) return;
    applyEvidence(threadId, evidence, selected.priority, reason);
  }

  function refreshSelectedFile(threadId) {
    const candidates = candidatesById.get(threadId);
    if (!candidates) {
      filesById.delete(threadId);
      return null;
    }

    let selected = null;
    for (const [filePath, priority] of candidates) {
      try {
        if (!fs.statSync(filePath).isFile()) {
          candidates.delete(filePath);
          continue;
        }
      } catch {
        candidates.delete(filePath);
        continue;
      }
      if (!selected || priority < selected.priority) selected = { filePath, priority };
    }
    if (!candidates.size) candidatesById.delete(threadId);
    if (!selected) {
      filesById.delete(threadId);
      return null;
    }
    filesById.set(threadId, selected);
    return selected;
  }

  const discovered = await Promise.all(roots.map(discoverRolloutFiles));
  for (let priority = 0; priority < discovered.length; priority += 1) {
    for (const filePath of discovered[priority]) {
      const threadId = threadIdFromRolloutPath(filePath);
      if (!threadId) continue;
      if (!candidatesById.has(threadId)) candidatesById.set(threadId, new Map());
      candidatesById.get(threadId).set(filePath, priority);
    }
  }
  for (const threadId of candidatesById.keys()) refreshSelectedFile(threadId);
  let initialCacheChanged = false;
  await mapInBatches([...filesById], 16, async ([threadId, selected]) => {
    const evidence = await readLatestLifecycle(selected.filePath);
    if (applyEvidence(threadId, evidence, selected.priority, 'initial-scan', false)) {
      initialCacheChanged = true;
    }
  });
  if (initialCacheChanged) await queueCacheWrite();
  await refreshAgentMetadata('initial-agent-metadata', false);

  for (let priority = 0; priority < roots.length; priority += 1) {
    const root = roots[priority];
    try {
      watchers.push(fs.watch(root, { recursive: true }, (_eventType, filename) => {
        if (closed || !filename) return;
        const relativePath = filename.toString();
        const threadId = threadIdFromRolloutPath(relativePath);
        if (!threadId) return;
        const changedPath = path.resolve(root, relativePath);
        const previousSelected = filesById.get(threadId);
        if (!candidatesById.has(threadId)) candidatesById.set(threadId, new Map());
        const candidates = candidatesById.get(threadId);
        try {
          if (fs.statSync(changedPath).isFile()) candidates.set(changedPath, priority);
          else candidates.delete(changedPath);
        } catch {
          candidates.delete(changedPath);
        }
        const selected = refreshSelectedFile(threadId);
        const selectedChanged = previousSelected?.filePath !== selected?.filePath;
        const selectedWasTouched = selected?.filePath === changedPath;

        if (!selected) {
          const wasComplete = completed.has(threadId);
          if (cachedCompleted.has(threadId)) completed.add(threadId);
          else completed.delete(threadId);
          if (wasComplete !== completed.has(threadId)) emit('rollout-source-removed');
        } else if (selectedChanged || selectedWasTouched) {
          const wasComplete = completed.has(threadId);
          if (selected.priority === 0 || !cachedCompleted.has(threadId)) {
            completed.delete(threadId);
          } else {
            completed.add(threadId);
          }
          if (wasComplete !== completed.has(threadId)) emit('rollout-changed-fail-closed');
        }

        const existing = timers.get(threadId);
        if (existing) clearTimeout(existing);
        if (!selected || (!selectedChanged && !selectedWasTouched)) {
          timers.delete(threadId);
          return;
        }
        const timer = setTimeout(() => {
          timers.delete(threadId);
          void inspect(threadId, selected, 'rollout-lifecycle-updated');
        }, 1000);
        timers.set(threadId, timer);
      }));
    } catch {
      // A missing optional root remains a read-only snapshot source and is retried on restart.
    }
  }

  if (agentMetadataDatabasePath) {
    agentMetadataTimer = setInterval(() => {
      void refreshAgentMetadata('agent-metadata-updated');
    }, agentMetadataRefreshMs);
    agentMetadataTimer.unref?.();
  }

  return {
    snapshot,
    watching: Boolean(watchers.length),
    async close() {
      closed = true;
      for (const watcher of watchers) watcher.close();
      if (agentMetadataTimer) clearInterval(agentMetadataTimer);
      agentMetadataTimer = null;
      for (const timer of timers.values()) clearTimeout(timer);
      timers.clear();
      await agentMetadataRefresh;
      await cacheWriteQueue;
    },
  };
}
