import { pathToFileURL } from 'node:url';

import { createCodexDevToolsTransport } from '../shared/codex-devtools-transport.mjs';
import { loadArchivedThreadIndex } from './archived-thread-index.mjs';

export const patchVersion = '0.2.2';

export async function installInRenderer(version, runtimeOptions = {}) {
  const globalKey = '__codexSidebarArchiveFilterHotpatch';
  const previous = window[globalKey];
  if (previous?.version === version) {
    const seedUpdated = previous.updateArchiveSeed?.(runtimeOptions.archivedThreadIndex) ?? false;
    const reconciled = await previous.reconcile('reinjected');
    return { ...previous.snapshot(), reused: true, reconciled, seedUpdated };
  }
  await previous?.remove?.();

  const refreshIntervalMs = Number.isFinite(runtimeOptions.refreshIntervalMs)
    ? Math.max(100, runtimeOptions.refreshIntervalMs)
    : 30_000;
  const retryIntervalMs = Number.isFinite(runtimeOptions.retryIntervalMs)
    ? Math.max(100, runtimeOptions.retryIntervalMs)
    : 2_000;
  const locateManagerOverride = runtimeOptions.locateManager;
  const orphanGracePeriodMs = Number.isFinite(runtimeOptions.orphanGracePeriodMs)
    ? Math.max(0, runtimeOptions.orphanGracePeriodMs)
    : 5 * 60_000;
  const managedIds = new Set();
  const apiObservedArchivedIds = new Set();
  const seededArchivedThreads = new Map();
  const knownLocalThreadIds = new Set();
  const orphanPlaceholderIds = new Set();
  const explicitlyUnarchivedIds = new Set();
  let activeManager = null;
  let managerCleanups = [];
  let scheduledTimer = null;
  let stopped = false;
  let inFlight = null;
  let managerReady = false;
  let archiveSeedLoaded = false;
  let archiveSeedSource = '';
  let archiveSeedError = '';
  let latestArchiveBatchCount = 0;
  let observedArchivedCount = 0;
  let suppressedObservedArchivedCount = 0;
  let suppressedConversationCount = 0;
  let repairCount = 0;
  let reconciliationCount = 0;
  let lastScanFibers = 0;
  let lastTimestampScanFibers = 0;
  let timestampRepairCount = 0;
  let orphanPlaceholderCount = 0;
  let suppressedOrphanPlaceholderCount = 0;
  let lastAttemptAt = 0;
  let lastReconciledAt = 0;
  let lastReason = '';
  let lastError = '';
  let archiveApiError = '';
  const localThreadIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  function isObject(value) {
    return value !== null && (typeof value === 'object' || typeof value === 'function');
  }

  function isManager(value) {
    try {
      return isObject(value)
        && typeof value.listArchivedThreads === 'function'
        && typeof value.getSuppressedArchivedConversationIds === 'function'
        && typeof value.suppressArchivedConversation === 'function'
        && typeof value.threadStore?.unsuppressArchivedConversation === 'function';
    } catch {
      return false;
    }
  }

  function managerFromRegistry(value) {
    if (!isObject(value)) return null;
    if (isManager(value)) return value;
    try {
      if (
        typeof value.getAll !== 'function'
        || typeof value.getForHostId !== 'function'
        || typeof value.getImplForHostId !== 'function'
      ) return null;
      const defaultManager = typeof value.getDefault === 'function' ? value.getDefault() : null;
      if (isManager(defaultManager)) return defaultManager;
      const managers = value.getAll();
      return Array.isArray(managers) ? managers.find(isManager) || null : null;
    } catch {
      return null;
    }
  }

  function managerFromValue(value) {
    const direct = managerFromRegistry(value);
    if (direct) return direct;
    if (!isObject(value)) return null;
    let names;
    try {
      names = Object.getOwnPropertyNames(value);
    } catch {
      return null;
    }
    if (names.length > 80) return null;
    for (const name of names.slice(0, 40)) {
      let descriptor;
      try {
        descriptor = Object.getOwnPropertyDescriptor(value, name);
      } catch {
        continue;
      }
      if (!descriptor || !Object.prototype.hasOwnProperty.call(descriptor, 'value')) continue;
      const nested = managerFromRegistry(descriptor.value);
      if (nested) return nested;
    }
    return null;
  }

  function normalizedThreadId(value) {
    const id = typeof value === 'string' ? value : value?.id;
    return typeof id === 'string' && id.length > 0 && id.length <= 200
      ? id.toLowerCase()
      : '';
  }

  function updateArchiveSeed(seed) {
    archiveSeedSource = typeof seed?.source === 'string' ? seed.source : '';
    archiveSeedError = typeof seed?.error === 'string' ? seed.error : '';
    archiveSeedLoaded = seed?.loaded === true;
    if (!archiveSeedLoaded || !Array.isArray(seed?.threads)) return false;

    const nextThreads = new Map();
    for (const value of seed.threads) {
      const id = normalizedThreadId(value);
      if (!id) continue;
      const timestamps = {};
      for (const field of ['createdAt', 'updatedAt', 'recencyAt']) {
        const timestamp = Number(value?.[field]);
        timestamps[field] = Number.isFinite(timestamp) && timestamp > 0 ? timestamp : 0;
      }
      nextThreads.set(id, { id, ...timestamps });
    }
    seededArchivedThreads.clear();
    for (const [id, value] of nextThreads) {
      seededArchivedThreads.set(id, value);
    }
    const nextKnownIds = new Set(
      (Array.isArray(seed?.knownThreadIds) ? seed.knownThreadIds : seed.threads)
        .map(normalizedThreadId)
        .filter(Boolean),
    );
    knownLocalThreadIds.clear();
    for (const id of nextKnownIds) knownLocalThreadIds.add(id);
    for (const id of [...orphanPlaceholderIds]) {
      if (knownLocalThreadIds.has(id)) orphanPlaceholderIds.delete(id);
    }
    return true;
  }

  function effectiveArchivedIds() {
    const ids = new Set();
    for (const id of seededArchivedThreads.keys()) {
      if (!explicitlyUnarchivedIds.has(id)) ids.add(id);
    }
    for (const id of apiObservedArchivedIds) {
      if (!explicitlyUnarchivedIds.has(id)) ids.add(id);
    }
    return ids;
  }

  function collectReactRoots() {
    const doc = globalThis.document;
    if (!doc) return [];
    const containers = [
      doc.getElementById?.('root'),
      doc.querySelector?.('body > [data-reactroot]'),
      doc.body?.firstElementChild,
    ].filter(Boolean);
    const roots = [];
    const seenRoots = new Set();
    for (const container of containers) {
      let names = [];
      try {
        names = Object.getOwnPropertyNames(container);
      } catch {
        continue;
      }
      for (const name of names) {
        if (!name.startsWith('__reactContainer$') && !name.startsWith('__reactFiber$')) continue;
        let fiber;
        try {
          fiber = container[name];
          while (fiber?.return) fiber = fiber.return;
        } catch {
          fiber = null;
        }
        if (fiber && !seenRoots.has(fiber)) {
          seenRoots.add(fiber);
          roots.push(fiber);
        }
      }
    }
    return roots;
  }

  function repairThreadSummaryTimestamps(value) {
    if (!isObject(value)) return 0;
    const id = normalizedThreadId(value.conversationId || value.id || value.threadId);
    const seed = seededArchivedThreads.get(id);
    if (!seed || explicitlyUnarchivedIds.has(id)) return 0;
    let repaired = 0;
    for (const field of ['createdAt', 'updatedAt', 'recencyAt']) {
      const expected = Number(seed[field]);
      const current = Number(value[field]);
      if (!Number.isFinite(expected) || expected <= 0) continue;
      if (Number.isFinite(current) && current >= 100_000_000_000) continue;
      try {
        value[field] = expected;
        repaired += 1;
      } catch {
        // React may freeze props in a future build; suppression remains the primary repair.
      }
    }
    return repaired;
  }

  function collectionHasThreadId(collection, id) {
    const candidates = [id, `local:${id}`];
    if (collection instanceof Set || collection instanceof Map) {
      return candidates.some((candidate) => collection.has(candidate));
    }
    return Array.isArray(collection) && collection.some((candidate) => candidates.includes(candidate));
  }

  function isSelectedThread(id) {
    const rows = globalThis.document?.querySelectorAll?.('[data-app-action-sidebar-thread-id]');
    if (!rows) return false;
    for (const row of rows) {
      const threadKey = String(row.getAttribute?.('data-app-action-sidebar-thread-id') || '').toLowerCase();
      const selected = row.getAttribute?.('data-app-action-sidebar-thread-selected');
      if ((threadKey === id || threadKey === `local:${id}`) && selected === 'true') return true;
    }
    return false;
  }

  function orphanPlaceholderId(value, manager, now) {
    if (!archiveSeedLoaded || !isObject(value)) return '';
    const id = normalizedThreadId(value.conversationId || value.id || value.threadId);
    if (!localThreadIdPattern.test(id)
      || seededArchivedThreads.has(id)
      || knownLocalThreadIds.has(id)
      || explicitlyUnarchivedIds.has(id)) return '';
    const title = String(value.title || '').trim().toLowerCase();
    const recencyAt = Number(value.recencyAt);
    if (title !== id || (Number.isFinite(recencyAt) && recencyAt > 0)) return '';
    const timestamps = [value.createdAt, value.updatedAt]
      .map(Number)
      .filter((timestamp) => Number.isFinite(timestamp) && timestamp > 0)
      .map((timestamp) => timestamp < 100_000_000_000 ? timestamp * 1000 : timestamp);
    const newestTimestamp = timestamps.length > 0 ? Math.max(...timestamps) : 0;
    if (newestTimestamp <= 0 || now - newestTimestamp < orphanGracePeriodMs) return '';
    if (collectionHasThreadId(manager?.threadStore?.activeConversationIds, id) || isSelectedThread(id)) return '';
    return id;
  }

  function scanThreadSummaries(manager) {
    const stack = collectReactRoots();
    const visited = new Set();
    const repairedValues = new Set();
    const startedAt = globalThis.performance?.now?.() ?? Date.now();
    const now = Date.now();
    const discoveredOrphanIds = new Set();
    let fibers = 0;
    let repaired = 0;
    while (stack.length > 0 && fibers < 12_000) {
      const fiber = stack.pop();
      if (!fiber || visited.has(fiber)) continue;
      visited.add(fiber);
      fibers += 1;
      for (const props of [fiber.memoizedProps, fiber.pendingProps]) {
        if (!isObject(props)) continue;
        for (const value of [props.threadSummary, props.entry?.summary, props.summary, props]) {
          if (!isObject(value) || repairedValues.has(value)) continue;
          repairedValues.add(value);
          repaired += repairThreadSummaryTimestamps(value);
          const orphanId = orphanPlaceholderId(value, manager, now);
          if (orphanId) discoveredOrphanIds.add(orphanId);
        }
      }
      if (fiber.sibling) stack.push(fiber.sibling);
      if (fiber.child) stack.push(fiber.child);
      const elapsed = (globalThis.performance?.now?.() ?? Date.now()) - startedAt;
      if (elapsed > 20) break;
    }
    for (const id of discoveredOrphanIds) orphanPlaceholderIds.add(id);
    for (const id of [...orphanPlaceholderIds]) {
      if (knownLocalThreadIds.has(id)
        || explicitlyUnarchivedIds.has(id)
        || collectionHasThreadId(manager?.threadStore?.activeConversationIds, id)) {
        orphanPlaceholderIds.delete(id);
      }
    }
    lastTimestampScanFibers = fibers;
    timestampRepairCount += repaired;
    return repaired;
  }

  function locateManagerFromReact() {
    const roots = collectReactRoots();

    const stack = [...roots];
    const visited = new Set();
    const startedAt = globalThis.performance?.now?.() ?? Date.now();
    let fibers = 0;
    while (stack.length > 0 && fibers < 12_000) {
      const fiber = stack.pop();
      if (!fiber || visited.has(fiber)) continue;
      visited.add(fiber);
      fibers += 1;

      let manager = managerFromValue(fiber.memoizedProps)
        || managerFromValue(fiber.pendingProps)
        || managerFromValue(fiber.stateNode);
      for (let hook = fiber.memoizedState, index = 0; hook && index < 80; hook = hook.next, index += 1) {
        manager = manager
          || managerFromValue(hook.memoizedState)
          || managerFromValue(hook.baseState)
          || managerFromValue(hook.queue?.lastRenderedState);
        if (manager) break;
      }
      for (
        let context = fiber.dependencies?.firstContext, index = 0;
        !manager && context && index < 80;
        context = context.next, index += 1
      ) {
        manager = managerFromValue(context.memoizedValue);
      }
      if (manager) {
        lastScanFibers = fibers;
        return manager;
      }

      if (fiber.sibling) stack.push(fiber.sibling);
      if (fiber.child) stack.push(fiber.child);
      const elapsed = (globalThis.performance?.now?.() ?? Date.now()) - startedAt;
      if (elapsed > 20) break;
    }
    lastScanFibers = fibers;
    return null;
  }

  function locateManager() {
    return typeof locateManagerOverride === 'function'
      ? locateManagerOverride()
      : locateManagerFromReact();
  }

  function normalizedIds(values) {
    if (!Array.isArray(values)) throw new TypeError('Codex returned a non-array thread collection.');
    return new Set(values.map(normalizedThreadId).filter(Boolean));
  }

  function currentSuppressedIds(manager) {
    const values = manager.getSuppressedArchivedConversationIds();
    if (!Array.isArray(values)) throw new TypeError('Codex returned a non-array suppression collection.');
    return new Set(values.map(normalizedThreadId).filter(Boolean));
  }

  function disposeManagerListeners() {
    for (const cleanup of managerCleanups.splice(0)) {
      try {
        if (typeof cleanup === 'function') cleanup();
        else cleanup?.unsubscribe?.();
      } catch {
        // A replaced Codex manager may already have disposed its listener set.
      }
    }
  }

  function eventThreadId(value) {
    if (typeof value === 'string') return value;
    if (!isObject(value)) return '';
    return [value.id, value.threadId, value.conversationId]
      .find((candidate) => typeof candidate === 'string') || '';
  }

  function updateObservedCounts(
    suppressedIds,
    archivedIds = effectiveArchivedIds(),
    orphanIds = orphanPlaceholderIds,
  ) {
    observedArchivedCount = archivedIds.size;
    suppressedObservedArchivedCount = [...archivedIds]
      .filter((observedId) => suppressedIds.has(observedId)).length;
    orphanPlaceholderCount = orphanIds.size;
    suppressedOrphanPlaceholderCount = [...orphanIds]
      .filter((orphanId) => suppressedIds.has(orphanId)).length;
    suppressedConversationCount = suppressedIds.size;
  }

  function releaseUnarchivedId(value) {
    const id = normalizedThreadId(value);
    if (!id) return false;
    const wasSeeded = seededArchivedThreads.delete(id);
    const wasApiObserved = apiObservedArchivedIds.delete(id);
    const wasOrphan = orphanPlaceholderIds.delete(id);
    const wasObserved = wasSeeded || wasApiObserved || wasOrphan;
    explicitlyUnarchivedIds.add(id);
    if (!activeManager) return wasObserved;
    try {
      const suppressedIds = currentSuppressedIds(activeManager);
      if (managedIds.has(id) && suppressedIds.has(id)) {
        activeManager.threadStore.unsuppressArchivedConversation(id);
        suppressedIds.delete(id);
      }
      managedIds.delete(id);
      updateObservedCounts(suppressedIds);
      return wasObserved;
    } catch (error) {
      lastError = `Unable to release an unarchived thread: ${error.message}`;
      return false;
    }
  }

  function addManagerListener(method, callback) {
    try {
      if (typeof activeManager?.[method] !== 'function') return;
      const cleanup = activeManager[method](callback);
      if (typeof cleanup === 'function' || cleanup?.unsubscribe) managerCleanups.push(cleanup);
    } catch {
      // Low-frequency reconciliation remains the fallback when an event API changes.
    }
  }

  function attachManager(manager) {
    if (manager === activeManager) return;
    disposeManagerListeners();
    activeManager = manager;
    managedIds.clear();
    apiObservedArchivedIds.clear();
    latestArchiveBatchCount = 0;
    observedArchivedCount = 0;
    suppressedObservedArchivedCount = 0;
    addManagerListener('addThreadArchivedListener', (value) => {
      const id = normalizedThreadId(eventThreadId(value));
      if (id) {
        explicitlyUnarchivedIds.delete(id);
        orphanPlaceholderIds.delete(id);
        apiObservedArchivedIds.add(id);
      }
      scheduleReconciliation(0);
    });
    addManagerListener('addThreadUnarchivedListener', (value) => {
      releaseUnarchivedId(eventThreadId(value));
      scheduleReconciliation(0);
    });
    addManagerListener('addThreadDeletedListener', (value) => {
      releaseUnarchivedId(eventThreadId(value));
      scheduleReconciliation(0);
    });
  }

  function snapshot() {
    let verification = 'waiting-for-manager';
    if (managerReady && lastError) verification = 'reconciliation-error';
    else if (managerReady && (
      observedArchivedCount !== suppressedObservedArchivedCount
      || orphanPlaceholderCount !== suppressedOrphanPlaceholderCount
    )) {
      verification = 'observed-suppression-incomplete';
    } else if (managerReady && archiveSeedLoaded) verification = 'local-archive-seed-applied';
    else if (managerReady) verification = 'archive-coverage-unverified';
    return {
      installed: !stopped,
      version,
      verification,
      managerReady,
      archiveSeedLoaded,
      archiveSeedSource,
      archiveSeedError,
      seededArchivedThreads: seededArchivedThreads.size,
      knownLocalThreads: knownLocalThreadIds.size,
      apiObservedArchivedThreads: apiObservedArchivedIds.size,
      latestArchiveBatchThreads: latestArchiveBatchCount,
      observedArchivedThreads: observedArchivedCount,
      suppressedObservedArchivedThreads: suppressedObservedArchivedCount,
      suppressedConversations: suppressedConversationCount,
      orphanPlaceholderThreads: orphanPlaceholderCount,
      suppressedOrphanPlaceholderThreads: suppressedOrphanPlaceholderCount,
      managedSuppressions: managedIds.size,
      repairs: repairCount,
      reconciliations: reconciliationCount,
      lastScanFibers,
      lastTimestampScanFibers,
      timestampRepairs: timestampRepairCount,
      lastAttemptAt,
      lastReconciledAt,
      lastReason,
      lastError,
      archiveApiError,
    };
  }

  async function performReconciliation(reason) {
    lastAttemptAt = Date.now();
    lastReason = reason;
    let manager;
    try {
      manager = locateManager();
    } catch (error) {
      managerReady = false;
      lastError = `Codex thread manager lookup failed: ${error.message}`;
      return false;
    }
    if (!isManager(manager)) {
      managerReady = false;
      lastError = 'Codex thread manager is not ready.';
      return false;
    }
    attachManager(manager);
    managerReady = true;

    try {
      let archiveBatchIds = new Set();
      try {
        const listedThreads = await manager.listArchivedThreads();
        if (stopped || manager !== activeManager) return false;
        archiveBatchIds = normalizedIds(listedThreads);
        archiveApiError = '';
      } catch (error) {
        archiveApiError = error?.message || 'archive-api-query-failed';
        if (!archiveSeedLoaded) throw error;
      }
      latestArchiveBatchCount = archiveBatchIds.size;
      for (const id of archiveBatchIds) {
        if (!explicitlyUnarchivedIds.has(id)) apiObservedArchivedIds.add(id);
      }
      scanThreadSummaries(manager);
      const archivedIds = effectiveArchivedIds();
      const orphanIds = new Set(
        [...orphanPlaceholderIds].filter((id) => !archivedIds.has(id)),
      );
      const effectiveIds = new Set([...archivedIds, ...orphanIds]);
      const suppressedIds = currentSuppressedIds(manager);
      let repaired = 0;
      for (const id of [...managedIds]) {
        if (effectiveIds.has(id)) continue;
        if (suppressedIds.has(id)) {
          manager.threadStore.unsuppressArchivedConversation(id);
          suppressedIds.delete(id);
        }
        managedIds.delete(id);
      }
      for (const id of effectiveIds) {
        if (suppressedIds.has(id)) continue;
        manager.suppressArchivedConversation(id);
        managedIds.add(id);
        suppressedIds.add(id);
        repaired += 1;
      }
      updateObservedCounts(suppressedIds, archivedIds, orphanIds);
      repairCount += repaired;
      reconciliationCount += 1;
      lastReconciledAt = Date.now();
      lastError = '';
      return true;
    } catch (error) {
      lastError = `Archive reconciliation failed: ${error.message}`;
      return false;
    }
  }

  function reconcile(reason = 'manual') {
    if (stopped) return Promise.resolve(false);
    if (inFlight) return inFlight;
    inFlight = performReconciliation(reason).finally(() => {
      inFlight = null;
    });
    return inFlight;
  }

  function scheduleReconciliation(delayMs) {
    if (stopped) return;
    if (scheduledTimer !== null) clearTimeout(scheduledTimer);
    scheduledTimer = setTimeout(async () => {
      scheduledTimer = null;
      const succeeded = await reconcile('scheduled');
      scheduleReconciliation(succeeded ? refreshIntervalMs : retryIntervalMs);
    }, delayMs);
    scheduledTimer?.unref?.();
  }

  function onFocus() {
    scheduleReconciliation(0);
  }

  function onVisibilityChange() {
    if (document.visibilityState !== 'hidden') scheduleReconciliation(0);
  }

  function remove() {
    if (stopped) return { installed: false, removed: false, restoredSuppressions: 0 };
    stopped = true;
    if (scheduledTimer !== null) clearTimeout(scheduledTimer);
    scheduledTimer = null;
    window.removeEventListener?.('focus', onFocus);
    document.removeEventListener?.('visibilitychange', onVisibilityChange);
    disposeManagerListeners();
    let restoredSuppressions = 0;
    if (activeManager) {
      let suppressedIds = new Set();
      try {
        suppressedIds = currentSuppressedIds(activeManager);
      } catch {
        // If Codex is tearing down, leave its in-memory state untouched.
      }
      for (const id of managedIds) {
        if (!suppressedIds.has(id)) continue;
        try {
          activeManager.threadStore.unsuppressArchivedConversation(id);
          restoredSuppressions += 1;
        } catch {
          // Removal remains best-effort during renderer teardown.
        }
      }
    }
    managedIds.clear();
    apiObservedArchivedIds.clear();
    seededArchivedThreads.clear();
    knownLocalThreadIds.clear();
    orphanPlaceholderIds.clear();
    explicitlyUnarchivedIds.clear();
    if (window[globalKey] === api) delete window[globalKey];
    return { installed: false, removed: true, restoredSuppressions };
  }

  const seedUpdated = updateArchiveSeed(runtimeOptions.archivedThreadIndex);
  const api = {
    version,
    reconcile,
    snapshot,
    updateArchiveSeed,
    remove,
  };
  window[globalKey] = api;
  window.addEventListener?.('focus', onFocus);
  document.addEventListener?.('visibilitychange', onVisibilityChange);
  const reconciled = await reconcile('install');
  scheduleReconciliation(reconciled ? refreshIntervalMs : retryIntervalMs);
  return { ...snapshot(), reused: false, reconciled, seedUpdated };
}

export function removeFromRenderer() {
  const patch = window.__codexSidebarArchiveFilterHotpatch;
  return patch?.remove?.() || { installed: false, removed: false, restoredSuppressions: 0 };
}

export function statusInRenderer() {
  const patch = window.__codexSidebarArchiveFilterHotpatch;
  return patch?.snapshot?.() || { installed: false };
}

export async function reconcileWatchedTargets({
  targets,
  injected,
  status,
  install,
  onEvent = () => {},
}) {
  if (!(injected instanceof Set)) throw new TypeError('injected must be a Set.');
  if (typeof status !== 'function') throw new TypeError('status must be a function.');
  if (typeof install !== 'function') throw new TypeError('install must be a function.');

  const liveTargets = Array.isArray(targets)
    ? targets.filter((target) => typeof target?.id === 'string' && target.id)
    : [];
  const liveTargetIds = new Set(liveTargets.map((target) => target.id));
  for (const targetId of injected) {
    if (!liveTargetIds.has(targetId)) injected.delete(targetId);
  }

  const events = [];
  const report = (outcome, target, error = '') => {
    const event = {
      outcome,
      targetId: target.id,
      url: target.url || '',
      error,
    };
    events.push(event);
    try {
      onEvent(event);
    } catch {
      // Diagnostics must not stop the watcher.
    }
  };

  for (const target of liveTargets) {
    if (injected.has(target.id)) {
      try {
        const current = await status(target);
        if (current?.installed === true) continue;
        injected.delete(target.id);
        report('renderer-lost', target);
      } catch (error) {
        injected.delete(target.id);
        report('status-failed', target, error?.message || 'renderer-status-failed');
      }
    }

    try {
      const result = await install(target);
      if (result?.installed === true) {
        injected.add(target.id);
        report('installed', target);
      } else {
        injected.delete(target.id);
        report('install-incomplete', target, 'renderer-reported-not-installed');
      }
    } catch (error) {
      injected.delete(target.id);
      report('install-failed', target, error?.message || 'renderer-install-failed');
    }
  }

  return events;
}

export async function main(args = process.argv.slice(2)) {
  const [mode, portArg] = args;
  if (mode === '--version') {
    process.stdout.write(JSON.stringify({ patchVersion }));
    return;
  }

  const port = Number(portArg);
  if (!['--once', '--watch-port', '--status', '--remove'].includes(mode) || !Number.isInteger(port)) {
    throw new Error(
      'Usage: node codex-sidebar-archive-filter-hotpatch.mjs '
      + '<--version|--once|--watch-port|--status|--remove> [port]',
    );
  }

  const { getTargets, evaluate, runForTargets } = createCodexDevToolsTransport({
    port,
    commandTimeoutMs: 8_000,
    targetFilter: (target) =>
      target.type === 'page'
      && target.url === 'app://-/index.html'
      && target.webSocketDebuggerUrl,
  });
  const archivedThreadIndex = ['--once', '--watch-port'].includes(mode)
    ? await loadArchivedThreadIndex()
    : null;
  const rendererOptions = archivedThreadIndex ? { archivedThreadIndex } : {};
  const installExpression = `(${installInRenderer.toString()})(${JSON.stringify(patchVersion)}, ${JSON.stringify(rendererOptions)})`;
  const removeExpression = `(${removeFromRenderer.toString()})()`;
  const statusExpression = `(${statusInRenderer.toString()})()`;

  if (mode === '--once') {
    process.stdout.write(JSON.stringify({ patchVersion, targets: await runForTargets(installExpression) }));
  } else if (mode === '--status') {
    process.stdout.write(JSON.stringify({ patchVersion, targets: await runForTargets(statusExpression) }));
  } else if (mode === '--remove') {
    process.stdout.write(JSON.stringify({ patchVersion, targets: await runForTargets(removeExpression) }));
  } else {
    const injected = new Set();
    let failures = 0;
    const recentDiagnostics = new Map();
    const logEvent = (event) => {
      if (event.outcome === 'installed') {
        process.stdout.write(`${new Date().toISOString()} ${event.outcome} ${event.targetId}\n`);
        return;
      }
      const key = `${event.outcome}:${event.targetId}:${event.error}`;
      const now = Date.now();
      if ((recentDiagnostics.get(key) || 0) > now - 30_000) return;
      recentDiagnostics.set(key, now);
      process.stderr.write(
        `${new Date().toISOString()} ${event.outcome} ${event.targetId} ${event.error || 'renderer-not-installed'}\n`,
      );
    };
    while (failures < 3) {
      try {
        const targets = await getTargets();
        failures = 0;
        await reconcileWatchedTargets({
          targets,
          injected,
          status: (target) => evaluate(target, statusExpression),
          install: (target) => evaluate(target, installExpression),
          onEvent: logEvent,
        });
      } catch (error) {
        failures += 1;
        process.stderr.write(`${new Date().toISOString()} target-discovery-failed ${error.message}\n`);
      }
      await new Promise((resolve) => setTimeout(resolve, 2_000));
    }
  }
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) await main();
