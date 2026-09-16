import assert from 'node:assert/strict';
import test from 'node:test';

import {
  installInRenderer,
  reconcileWatchedTargets,
  removeFromRenderer,
  statusInRenderer,
} from './codex-sidebar-archive-filter-hotpatch.mjs';

function createManager({
  archived = [],
  archivedBatches = null,
  suppressed = [],
  active = [],
  listError = null,
} = {}) {
  const archivedIds = new Set(archived);
  const suppressedIds = new Set(suppressed);
  const listeners = {
    archived: new Set(),
    unarchived: new Set(),
    deleted: new Set(),
  };
  const calls = { suppress: [], unsuppress: [], list: 0 };
  const manager = {
    archivedIds,
    suppressedIds,
    calls,
    async listArchivedThreads() {
      calls.list += 1;
      if (listError) throw listError;
      if (Array.isArray(archivedBatches)) {
        const index = Math.min(calls.list - 1, Math.max(archivedBatches.length - 1, 0));
        return (archivedBatches[index] || []).map((id) => ({ id }));
      }
      return [...archivedIds].map((id) => ({ id }));
    },
    getSuppressedArchivedConversationIds() {
      return [...suppressedIds];
    },
    suppressArchivedConversation(id) {
      calls.suppress.push(id);
      suppressedIds.add(id);
    },
    threadStore: {
      activeConversationIds: new Set(active),
      unsuppressArchivedConversation(id) {
        calls.unsuppress.push(id);
        suppressedIds.delete(id);
      },
    },
    addThreadArchivedListener(callback) {
      listeners.archived.add(callback);
      return () => listeners.archived.delete(callback);
    },
    addThreadUnarchivedListener(callback) {
      listeners.unarchived.add(callback);
      return () => listeners.unarchived.delete(callback);
    },
    addThreadDeletedListener(callback) {
      listeners.deleted.add(callback);
      return () => listeners.deleted.delete(callback);
    },
    emit(type, id) {
      for (const callback of listeners[type]) callback(id);
    },
  };
  return manager;
}

function installFixture({ reactRoot = null } = {}) {
  const windowListeners = new Map();
  const documentListeners = new Map();
  const fakeWindow = {
    addEventListener(type, callback) { windowListeners.set(type, callback); },
    removeEventListener(type, callback) {
      if (windowListeners.get(type) === callback) windowListeners.delete(type);
    },
  };
  const fakeDocument = {
    visibilityState: 'visible',
    getElementById(id) { return id === 'root' && reactRoot ? reactContainer : null; },
    querySelector() { return null; },
    body: { firstElementChild: null },
    addEventListener(type, callback) { documentListeners.set(type, callback); },
    removeEventListener(type, callback) {
      if (documentListeners.get(type) === callback) documentListeners.delete(type);
    },
  };
  const reactContainer = reactRoot ? { '__reactContainer$fixture': reactRoot } : null;
  const previousWindow = globalThis.window;
  const previousDocument = globalThis.document;
  globalThis.window = fakeWindow;
  globalThis.document = fakeDocument;
  return {
    restore() {
      globalThis.window?.__codexSidebarArchiveFilterHotpatch?.remove?.();
      if (previousWindow === undefined) delete globalThis.window;
      else globalThis.window = previousWindow;
      if (previousDocument === undefined) delete globalThis.document;
      else globalThis.document = previousDocument;
    },
  };
}

function archiveIndexFor(ids, timestamps = {}) {
  return {
    loaded: true,
    source: 'fixture-read-only',
    error: '',
    knownThreadIds: [...ids],
    threads: ids.map((id) => ({
      id,
      createdAt: timestamps.createdAt || 0,
      updatedAt: timestamps.updatedAt || 0,
      recencyAt: timestamps.recencyAt || 0,
    })),
  };
}

function placeholderFiber(id, overrides = {}) {
  const summary = {
    conversationId: id,
    createdAt: Date.now() - 60_000,
    updatedAt: Date.now() - 60_000,
    recencyAt: 0,
    title: id,
    ...overrides,
  };
  const leaf = { memoizedProps: { threadSummary: summary }, pendingProps: null };
  const reactRoot = { child: leaf };
  leaf.return = reactRoot;
  return { reactRoot, summary };
}

function optionsFor(managerOrLocator, extra = {}) {
  return {
    locateManager: typeof managerOrLocator === 'function'
      ? managerOrLocator
      : () => managerOrLocator,
    refreshIntervalMs: 60_000,
    retryIntervalMs: 60_000,
    ...extra,
  };
}

test('repairs a partial five-of-nine suppression set', async () => {
  const fixture = installFixture();
  const ids = Array.from({ length: 9 }, (_, index) => `thread-${index + 1}`);
  const manager = createManager({ archived: ids, suppressed: ids.slice(0, 5) });
  try {
    const result = await installInRenderer('fixture', optionsFor(manager));
    assert.equal(result.verification, 'archive-coverage-unverified');
    assert.equal(result.latestArchiveBatchThreads, 9);
    assert.equal(result.observedArchivedThreads, 9);
    assert.equal(result.suppressedObservedArchivedThreads, 9);
    assert.equal(result.managedSuppressions, 4);
    assert.equal(result.repairs, 4);
    assert.deepEqual(manager.calls.suppress, ids.slice(5));
  } finally {
    fixture.restore();
  }
});

test('same-version reinjection is idempotent', async () => {
  const fixture = installFixture();
  const manager = createManager({ archived: ['a', 'b'], suppressed: ['a'] });
  try {
    await installInRenderer('fixture', optionsFor(manager));
    const second = await installInRenderer('fixture', optionsFor(manager));
    assert.equal(second.reused, true);
    assert.equal(manager.calls.suppress.length, 1);
    assert.equal(statusInRenderer().repairs, 1);
  } finally {
    fixture.restore();
  }
});

test('watcher repairs a renderer reload that retains its DevTools target id', async () => {
  const target = { id: 'stable-target', url: 'app://-/index.html' };
  const injected = new Set([target.id]);
  const events = [];
  let installed = false;
  let installs = 0;

  await reconcileWatchedTargets({
    targets: [target],
    injected,
    status: async () => ({ installed }),
    install: async () => {
      installs += 1;
      installed = true;
      return { installed: true };
    },
    onEvent: (event) => events.push(event),
  });

  assert.equal(installs, 1);
  assert.equal(injected.has(target.id), true);
  assert.equal(events.some((event) => event.outcome === 'renderer-lost'), true);
  assert.equal(events.some((event) => event.outcome === 'installed'), true);

  await reconcileWatchedTargets({
    targets: [target],
    injected,
    status: async () => ({ installed }),
    install: async () => {
      installs += 1;
      return { installed: true };
    },
  });
  assert.equal(installs, 1, 'verified renderer state must not be reinjected repeatedly');
});

test('watcher does not cache an incomplete injection', async () => {
  const target = { id: 'not-ready-target', url: 'app://-/index.html' };
  const injected = new Set();
  let attempts = 0;

  const attempt = () => reconcileWatchedTargets({
    targets: [target],
    injected,
    status: async () => ({ installed: false }),
    install: async () => {
      attempts += 1;
      return { installed: false };
    },
  });

  await attempt();
  await attempt();
  assert.equal(attempts, 2);
  assert.equal(injected.has(target.id), false);
});

test('accumulates partial 9 -> 0 -> 1 batches without losing suppression ownership', async () => {
  const fixture = installFixture();
  const firstBatch = Array.from({ length: 9 }, (_, index) => `thread-${index + 1}`);
  const manager = createManager({
    archivedBatches: [firstBatch, [], ['thread-10']],
    suppressed: firstBatch.slice(0, 5),
  });
  try {
    const installed = await installInRenderer('fixture', optionsFor(manager));
    assert.equal(installed.verification, 'archive-coverage-unverified');
    assert.equal(installed.latestArchiveBatchThreads, 9);
    assert.equal(installed.observedArchivedThreads, 9);
    assert.equal(installed.managedSuppressions, 4);

    await window.__codexSidebarArchiveFilterHotpatch.reconcile('empty-batch');
    const afterEmpty = statusInRenderer();
    assert.equal(afterEmpty.verification, 'archive-coverage-unverified');
    assert.equal(afterEmpty.latestArchiveBatchThreads, 0);
    assert.equal(afterEmpty.observedArchivedThreads, 9);
    assert.equal(afterEmpty.managedSuppressions, 4);

    await window.__codexSidebarArchiveFilterHotpatch.reconcile('next-increment');
    const afterIncrement = statusInRenderer();
    assert.equal(afterIncrement.verification, 'archive-coverage-unverified');
    assert.equal(afterIncrement.latestArchiveBatchThreads, 1);
    assert.equal(afterIncrement.observedArchivedThreads, 10);
    assert.equal(afterIncrement.suppressedObservedArchivedThreads, 10);
    assert.equal(afterIncrement.managedSuppressions, 5);

    const removed = removeFromRenderer();
    assert.equal(removed.restoredSuppressions, 5);
    assert.deepEqual([...manager.suppressedIds], firstBatch.slice(0, 5));
  } finally {
    fixture.restore();
  }
});

test('never treats empty or one-item batches as complete against 27 exclusions', async () => {
  const fixture = installFixture();
  const suppressed = Array.from({ length: 27 }, (_, index) => `thread-${index + 1}`);
  const manager = createManager({ archivedBatches: [[], ['thread-1']], suppressed });
  try {
    const installed = await installInRenderer('fixture', optionsFor(manager));
    assert.equal(installed.verification, 'archive-coverage-unverified');
    assert.equal(installed.latestArchiveBatchThreads, 0);
    assert.equal(installed.observedArchivedThreads, 0);
    assert.equal(installed.suppressedConversations, 27);

    await window.__codexSidebarArchiveFilterHotpatch.reconcile('one-item-batch');
    const afterOne = statusInRenderer();
    assert.equal(afterOne.verification, 'archive-coverage-unverified');
    assert.equal(afterOne.latestArchiveBatchThreads, 1);
    assert.equal(afterOne.observedArchivedThreads, 1);
    assert.equal(afterOne.suppressedObservedArchivedThreads, 1);
    assert.equal(afterOne.suppressedConversations, 27);
  } finally {
    fixture.restore();
  }
});

test('cold-start seed repairs archived rows when the renderer API begins with zero', async () => {
  const fixture = installFixture();
  const excluded = Array.from({ length: 27 }, (_, index) => `excluded-${index + 1}`);
  const seeded = Array.from({ length: 9 }, (_, index) => `archived-${index + 1}`);
  const manager = createManager({ archivedBatches: [[], []], suppressed: excluded });
  try {
    const installed = await installInRenderer('fixture', optionsFor(manager, {
      archivedThreadIndex: archiveIndexFor(seeded),
    }));
    assert.equal(installed.verification, 'local-archive-seed-applied');
    assert.equal(installed.archiveSeedLoaded, true);
    assert.equal(installed.seededArchivedThreads, 9);
    assert.equal(installed.apiObservedArchivedThreads, 0);
    assert.equal(installed.latestArchiveBatchThreads, 0);
    assert.equal(installed.observedArchivedThreads, 9);
    assert.equal(installed.suppressedObservedArchivedThreads, 9);
    assert.equal(installed.suppressedConversations, 36);
    assert.equal(installed.managedSuppressions, 9);
    assert.deepEqual(manager.calls.suppress, seeded);
    assert.equal(manager.calls.unsuppress.length, 0);
  } finally {
    fixture.restore();
  }
});

test('unarchive event releases a seeded suppression and rejects a stale API batch', async () => {
  const fixture = installFixture();
  const manager = createManager({ archivedBatches: [[], ['seeded-thread']] });
  try {
    await installInRenderer('fixture', optionsFor(manager, {
      archivedThreadIndex: archiveIndexFor(['seeded-thread']),
    }));
    assert.equal(manager.suppressedIds.has('seeded-thread'), true);

    manager.emit('unarchived', 'seeded-thread');
    assert.equal(manager.suppressedIds.has('seeded-thread'), false);
    await window.__codexSidebarArchiveFilterHotpatch.reconcile('stale-api-batch');

    const status = statusInRenderer();
    assert.equal(status.seededArchivedThreads, 0);
    assert.equal(status.apiObservedArchivedThreads, 0);
    assert.equal(status.observedArchivedThreads, 0);
    assert.equal(manager.suppressedIds.has('seeded-thread'), false);
    assert.deepEqual(manager.calls.suppress, ['seeded-thread']);
    assert.deepEqual(manager.calls.unsuppress, ['seeded-thread']);
  } finally {
    fixture.restore();
  }
});

test('repairs invalid archived summary timestamps from the read-only seed', async () => {
  const id = '019fa197-464c-7031-8fd2-c01eab763a27';
  const summary = {
    conversationId: id,
    createdAt: 1_785_122_473,
    updatedAt: 1_785_122_492_602,
    recencyAt: 0,
  };
  const leaf = { memoizedProps: { threadSummary: summary }, pendingProps: null };
  const reactRoot = { child: leaf };
  leaf.return = reactRoot;
  const fixture = installFixture({ reactRoot });
  const manager = createManager({ archivedBatches: [[]] });
  try {
    const installed = await installInRenderer('fixture', optionsFor(manager, {
      archivedThreadIndex: archiveIndexFor([id], {
        createdAt: 1_785_122_473_548,
        updatedAt: 1_785_122_492_602,
        recencyAt: 1_785_122_474_351,
      }),
    }));
    assert.equal(installed.timestampRepairs, 2);
    assert.equal(summary.createdAt, 1_785_122_473_548);
    assert.equal(summary.updatedAt, 1_785_122_492_602);
    assert.equal(summary.recencyAt, 1_785_122_474_351);
  } finally {
    fixture.restore();
  }
});

test('suppresses an aged UUID placeholder that is absent from the local thread index', async () => {
  const id = '019f270e-6778-7292-9632-e11a9a664660';
  const { reactRoot } = placeholderFiber(id);
  const fixture = installFixture({ reactRoot });
  const manager = createManager();
  try {
    const installed = await installInRenderer('fixture', optionsFor(manager, {
      archivedThreadIndex: { ...archiveIndexFor([]), knownThreadIds: [] },
      orphanGracePeriodMs: 0,
    }));
    assert.equal(installed.orphanPlaceholderThreads, 1);
    assert.equal(installed.suppressedOrphanPlaceholderThreads, 1);
    assert.equal(installed.timestampRepairs, 0);
    assert.deepEqual(manager.calls.suppress, [id]);

    reactRoot.child = null;
    await window.__codexSidebarArchiveFilterHotpatch.reconcile('placeholder-no-longer-rendered');
    assert.equal(statusInRenderer().orphanPlaceholderThreads, 1);
    assert.deepEqual(manager.calls.unsuppress, []);
  } finally {
    fixture.restore();
  }
});

test('preserves known, fresh, titled, and active local thread summaries', async () => {
  const knownId = '019f270e-6778-7292-9632-e11a9a664660';
  const freshId = '019f270e-ab02-7763-b828-9f2a9167c009';
  const titledId = '019f270e-ab02-7763-b828-9f2a9167c010';
  const activeId = '019f270e-ab02-7763-b828-9f2a9167c011';
  const known = placeholderFiber(knownId);
  const fresh = placeholderFiber(freshId, { createdAt: Date.now(), updatedAt: Date.now() });
  const titled = placeholderFiber(titledId, { title: 'real title' });
  const active = placeholderFiber(activeId);
  known.reactRoot.child.sibling = fresh.reactRoot.child;
  fresh.reactRoot.child.sibling = titled.reactRoot.child;
  titled.reactRoot.child.sibling = active.reactRoot.child;
  const fixture = installFixture({ reactRoot: known.reactRoot });
  const manager = createManager({ active: [activeId] });
  try {
    const installed = await installInRenderer('fixture', optionsFor(manager, {
      archivedThreadIndex: { ...archiveIndexFor([]), knownThreadIds: [knownId] },
      orphanGracePeriodMs: 30_000,
    }));
    assert.equal(installed.orphanPlaceholderThreads, 0);
    assert.deepEqual(manager.calls.suppress, []);
  } finally {
    fixture.restore();
  }
});

test('releases an orphan placeholder when it appears in a refreshed local index', async () => {
  const id = '019f270e-6778-7292-9632-e11a9a664660';
  const { reactRoot } = placeholderFiber(id);
  const fixture = installFixture({ reactRoot });
  const manager = createManager();
  try {
    await installInRenderer('fixture', optionsFor(manager, {
      archivedThreadIndex: { ...archiveIndexFor([]), knownThreadIds: [] },
      orphanGracePeriodMs: 0,
    }));
    assert.equal(manager.suppressedIds.has(id), true);

    await installInRenderer('fixture', optionsFor(manager, {
      archivedThreadIndex: { ...archiveIndexFor([]), knownThreadIds: [id] },
      orphanGracePeriodMs: 0,
    }));
    assert.equal(manager.suppressedIds.has(id), false);
    assert.deepEqual(manager.calls.unsuppress, [id]);
  } finally {
    fixture.restore();
  }
});

test('unarchive event releases a suppression managed by the patch', async () => {
  const fixture = installFixture();
  const manager = createManager({ archived: ['archived-thread'] });
  try {
    await installInRenderer('fixture', optionsFor(manager));
    assert.equal(manager.suppressedIds.has('archived-thread'), true);
    manager.archivedIds.delete('archived-thread');
    manager.emit('unarchived', 'archived-thread');
    assert.equal(manager.suppressedIds.has('archived-thread'), false);
    assert.deepEqual(manager.calls.unsuppress, ['archived-thread']);
  } finally {
    fixture.restore();
  }
});

test('unarchive event forgets an observed suppression originally owned by Codex', async () => {
  const fixture = installFixture();
  const manager = createManager({ archived: ['native-suppression'], suppressed: ['native-suppression'] });
  try {
    await installInRenderer('fixture', optionsFor(manager));
    assert.equal(statusInRenderer().managedSuppressions, 0);
    manager.archivedIds.delete('native-suppression');
    manager.suppressedIds.delete('native-suppression');
    manager.emit('unarchived', 'native-suppression');
    assert.equal(statusInRenderer().observedArchivedThreads, 0);
    await window.__codexSidebarArchiveFilterHotpatch.reconcile('after-native-unarchive');
    assert.equal(manager.suppressedIds.has('native-suppression'), false);
    assert.equal(manager.calls.suppress.length, 0);
  } finally {
    fixture.restore();
  }
});

test('waits safely when the Codex manager is not ready', async () => {
  const fixture = installFixture();
  try {
    const result = await installInRenderer('fixture', optionsFor(() => null));
    assert.equal(result.installed, true);
    assert.equal(result.managerReady, false);
    assert.equal(result.verification, 'waiting-for-manager');
    assert.match(result.lastError, /not ready/i);
  } finally {
    fixture.restore();
  }
});

test('archive query failure preserves the existing suppression set', async () => {
  const fixture = installFixture();
  const manager = createManager({
    suppressed: ['already-suppressed'],
    listError: new Error('fixture query failure'),
  });
  try {
    const result = await installInRenderer('fixture', optionsFor(manager));
    assert.equal(result.verification, 'reconciliation-error');
    assert.deepEqual([...manager.suppressedIds], ['already-suppressed']);
    assert.equal(manager.calls.suppress.length, 0);
    assert.equal(manager.calls.unsuppress.length, 0);
  } finally {
    fixture.restore();
  }
});

test('remove restores only suppressions added by this patch', async () => {
  const fixture = installFixture();
  const manager = createManager({ archived: ['original', 'repair'], suppressed: ['original'] });
  try {
    await installInRenderer('fixture', optionsFor(manager));
    const result = removeFromRenderer();
    assert.deepEqual(result, { installed: false, removed: true, restoredSuppressions: 1 });
    assert.deepEqual([...manager.suppressedIds], ['original']);
    assert.deepEqual(statusInRenderer(), { installed: false });
  } finally {
    fixture.restore();
  }
});
