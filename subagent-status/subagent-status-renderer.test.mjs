import assert from 'node:assert/strict';
import test from 'node:test';

import {
  installInRenderer,
  removeFromRenderer,
  statusInRenderer,
  updateEvidenceInRenderer,
} from './codex-subagent-status-hotpatch.mjs';

function installIdleFixture() {
  const listeners = new Map();
  const previousWindow = Object.prototype.hasOwnProperty.call(globalThis, 'window')
    ? { exists: true, value: globalThis.window }
    : { exists: false };
  const previousDocument = Object.prototype.hasOwnProperty.call(globalThis, 'document')
    ? { exists: true, value: globalThis.document }
    : { exists: false };

  globalThis.window = {};
  globalThis.document = {
    hidden: true,
    querySelectorAll() { return []; },
    addEventListener(type, callback) { listeners.set(type, callback); },
    removeEventListener(type, callback) {
      if (listeners.get(type) === callback) listeners.delete(type);
    },
  };

  return {
    listeners,
    restoreGlobals() {
      if (previousWindow.exists) globalThis.window = previousWindow.value;
      else delete globalThis.window;
      if (previousDocument.exists) globalThis.document = previousDocument.value;
      else delete globalThis.document;
    },
  };
}

function installPanelProbeFixture(panelVisible = false) {
  const listeners = new Map();
  const intervals = new Set();
  const previousWindow = Object.prototype.hasOwnProperty.call(globalThis, 'window')
    ? { exists: true, value: globalThis.window }
    : { exists: false };
  const previousDocument = Object.prototype.hasOwnProperty.call(globalThis, 'document')
    ? { exists: true, value: globalThis.document }
    : { exists: false };
  const previousSetInterval = globalThis.setInterval;
  const previousClearInterval = globalThis.clearInterval;

  globalThis.setInterval = (callback) => {
    intervals.add(callback);
    return callback;
  };
  globalThis.clearInterval = (callback) => intervals.delete(callback);
  globalThis.window = {};
  const heading = {
    isConnected: true,
    textContent: 'Active · 1',
    getClientRects() { return [{}]; },
  };
  globalThis.document = {
    hidden: false,
    querySelectorAll(selector) {
      if (panelVisible && selector === 'h2') return [heading];
      return [];
    },
    addEventListener(type, callback) { listeners.set(type, callback); },
    removeEventListener(type, callback) {
      if (listeners.get(type) === callback) listeners.delete(type);
    },
  };

  return {
    listeners,
    runPanelProbes() {
      for (const callback of [...intervals]) callback();
    },
    restoreGlobals() {
      globalThis.setInterval = previousSetInterval;
      globalThis.clearInterval = previousClearInterval;
      if (previousWindow.exists) globalThis.window = previousWindow.value;
      else delete globalThis.window;
      if (previousDocument.exists) globalThis.document = previousDocument.value;
      else delete globalThis.document;
    },
  };
}

function installProjectionFixture(agent) {
  const listeners = new Map();
  const previousWindow = Object.prototype.hasOwnProperty.call(globalThis, 'window')
    ? { exists: true, value: globalThis.window }
    : { exists: false };
  const previousDocument = Object.prototype.hasOwnProperty.call(globalThis, 'document')
    ? { exists: true, value: globalThis.document }
    : { exists: false };

  const opener = {
    isConnected: true,
    getClientRects() { return [{}]; },
    getAttribute(name) { return name === 'aria-label' ? '打开子代理' : null; },
  };
  opener.__reactFiber$fixture = {
    memoizedProps: { subagents: [agent] },
    pendingProps: null,
    return: null,
  };

  globalThis.window = {};
  globalThis.document = {
    hidden: false,
    querySelectorAll(selector) {
      if (selector === 'button,[role="button"]') return [opener];
      return [];
    },
    addEventListener(type, callback) { listeners.set(type, callback); },
    removeEventListener(type, callback) {
      if (listeners.get(type) === callback) listeners.delete(type);
    },
  };

  return {
    listeners,
    restoreGlobals() {
      if (previousWindow.exists) globalThis.window = previousWindow.value;
      else delete globalThis.window;
      if (previousDocument.exists) globalThis.document = previousDocument.value;
      else delete globalThis.document;
    },
  };
}

function installCurrentSummaryFixture(agents, labelText = '5 个运行中') {
  const listeners = new Map();
  const previousWindow = Object.prototype.hasOwnProperty.call(globalThis, 'window')
    ? { exists: true, value: globalThis.window }
    : { exists: false };
  const previousDocument = Object.prototype.hasOwnProperty.call(globalThis, 'document')
    ? { exists: true, value: globalThis.document }
    : { exists: false };

  const label = { isConnected: true, textContent: labelText };
  const fiber = {
    memoizedProps: { backgroundAgents: agents },
    pendingProps: { backgroundAgents: agents },
    return: null,
  };
  const opener = {
    isConnected: true,
    getClientRects() { return [{}]; },
    getAttribute(name) { return name === 'aria-label' ? '打开子代理' : null; },
    querySelector(selector) {
      return selector === '[data-slot="thread-summary-panel-item-label"]' ? label : null;
    },
  };
  opener.__reactFiber$fixture = fiber;

  globalThis.window = {};
  globalThis.document = {
    hidden: false,
    documentElement: { lang: 'zh-CN' },
    querySelectorAll(selector) {
      if (selector === 'button,[role="button"]') return [opener];
      return [];
    },
    addEventListener(type, callback) { listeners.set(type, callback); },
    removeEventListener(type, callback) {
      if (listeners.get(type) === callback) listeners.delete(type);
    },
  };

  return {
    label,
    listeners,
    setAgents(nextAgents) {
      fiber.memoizedProps = { backgroundAgents: nextAgents };
      fiber.pendingProps = { backgroundAgents: nextAgents };
    },
    restoreGlobals() {
      if (previousWindow.exists) globalThis.window = previousWindow.value;
      else delete globalThis.window;
      if (previousDocument.exists) globalThis.document = previousDocument.value;
      else delete globalThis.document;
    },
  };
}

test('installs, reuses, updates evidence, and removes the idle renderer patch', () => {
  const fixture = installIdleFixture();
  try {
    const installed = installInRenderer({ ids: ['a'], revision: 1, updatedAt: 10 }, 'fixture-version');
    assert.equal(installed.installed, true);
    assert.equal(installed.version, 'fixture-version');
    assert.equal(installed.completionEvidenceCount, 1);
    assert.equal(installed.panelProbeInstalled, true);
    assert.equal(fixture.listeners.size, 2);

    const reused = installInRenderer({ ids: ['a', 'b'], revision: 2, updatedAt: 20 }, 'fixture-version');
    assert.equal(reused.reused, true);
    assert.equal(reused.completionEvidenceCount, 2);
    assert.equal(statusInRenderer().completionEvidenceCount, 2);

    const updated = updateEvidenceInRenderer({ ids: ['b'], revision: 3, updatedAt: 30 });
    assert.equal(updated.completionEvidenceCount, 1);
    assert.deepEqual(removeFromRenderer(), { installed: false, removed: true });
    assert.equal(fixture.listeners.size, 0);
    assert.deepEqual(statusInRenderer(), { installed: false });
  } finally {
    globalThis.window?.__codexSubagentStatusHotpatch?.disconnect?.();
    fixture.restoreGlobals();
  }
});

test('keeps the closed-panel probe from rerunning full status projection', () => {
  const fixture = installPanelProbeFixture();
  try {
    const installed = installInRenderer({ ids: [], revision: 1, updatedAt: 10 }, 'closed-panel-version');
    assert.equal(installed.projectionRuns, 1);
    assert.equal(installed.summaryProjectionRuns, 1);

    fixture.runPanelProbes();
    fixture.runPanelProbes();
    const status = statusInRenderer();
    assert.equal(status.projectionRuns, 1);
    assert.equal(status.summaryProjectionRuns, 1);
    assert.equal(status.lastProjectionReason, 'install');
  } finally {
    globalThis.window?.__codexSubagentStatusHotpatch?.disconnect?.();
    fixture.restoreGlobals();
  }
});

test('keeps probing a visible legacy panel without a tab id', () => {
  const fixture = installPanelProbeFixture(true);
  try {
    const installed = installInRenderer({ ids: [], revision: 1, updatedAt: 10 }, 'legacy-panel-version');
    assert.equal(installed.projectionRuns, 2);
    assert.equal(installed.lastProjectionReason, 'visible-panel-probe');

    fixture.runPanelProbes();
    const status = statusInRenderer();
    assert.equal(status.projectionRuns, 3);
    assert.equal(status.lastProjectionReason, 'visible-panel-probe');
  } finally {
    globalThis.window?.__codexSubagentStatusHotpatch?.disconnect?.();
    fixture.restoreGlobals();
  }
});

test('projects persisted completion evidence before the panel opens and restores fail-closed', () => {
  const id = '019ff0e3-5823-7c92-b87d-6128dfc76c17';
  const agent = {
    conversationId: id,
    parentConversationId: '019ff090-333b-7153-85fa-ee0d41351784',
    displayName: 'Architecture scan',
    status: 'running',
  };
  const fixture = installProjectionFixture(agent);
  try {
    const installed = installInRenderer({ ids: [id], revision: 1, updatedAt: 10 }, 'projection-version');
    assert.equal(agent.status, 'done');
    assert.equal(installed.projectedCompletedCount, 1);
    assert.deepEqual(installed.lastProjectedIds, [id]);

    const activeAgain = updateEvidenceInRenderer({ ids: [], revision: 2, updatedAt: 20 });
    assert.equal(agent.status, 'running');
    assert.equal(activeAgain.projectedCompletedCount, 0);

    updateEvidenceInRenderer({ ids: [id], revision: 3, updatedAt: 30 });
    assert.equal(agent.status, 'done');
    assert.deepEqual(removeFromRenderer(), { installed: false, removed: true });
    assert.equal(agent.status, 'running');
    assert.equal(fixture.listeners.size, 0);
  } finally {
    globalThis.window?.__codexSubagentStatusHotpatch?.disconnect?.();
    fixture.restoreGlobals();
  }
});

test('reconciles current backgroundAgents summaries after restart and object replacement', () => {
  const ids = [
    '019ff0e3-5823-7c92-b87d-6128dfc76c17',
    '019fffff-9b93-70f1-8db7-29fc000456c2',
    '01a0035b-f031-7fb3-acd3-89e0384cdf6e',
    '01a00652-51a8-7eb1-b947-64a16f2876cc',
    '01a00700-0000-7000-8000-000000000001',
  ];
  const createAgents = () => ids.map((conversationId, index) => ({
    conversationId,
    parentConversationId: '019ff090-333b-7153-85fa-ee0d41351784',
    displayName: `Agent ${index + 1}`,
    status: 'running',
  }));
  const initialAgents = createAgents();
  const fixture = installCurrentSummaryFixture(initialAgents);
  try {
    const installed = installInRenderer({ ids: ids.slice(0, 4), revision: 1, updatedAt: 10 }, 'current-summary-version');
    assert.deepEqual(initialAgents.map((agent) => agent.status), [
      'done', 'done', 'done', 'done', 'running',
    ]);
    assert.equal(fixture.label.textContent, '1 个运行中');
    assert.equal(installed.projectedSummaryCompletedCount, 4);

    const rehydratedAgents = createAgents();
    fixture.setAgents(rehydratedAgents);
    const updated = updateEvidenceInRenderer({ ids, revision: 2, updatedAt: 20 });
    assert.deepEqual(rehydratedAgents.map((agent) => agent.status), [
      'done', 'done', 'done', 'done', 'done',
    ]);
    assert.equal(fixture.label.textContent, '5 完成');
    assert.equal(updated.projectedSummaryCompletedCount, 5);

    assert.deepEqual(removeFromRenderer(), { installed: false, removed: true });
    assert.deepEqual(rehydratedAgents.map((agent) => agent.status), [
      'running', 'running', 'running', 'running', 'running',
    ]);
    assert.equal(fixture.label.textContent, '5 个运行中');
    assert.equal(fixture.listeners.size, 0);
  } finally {
    globalThis.window?.__codexSubagentStatusHotpatch?.disconnect?.();
    fixture.restoreGlobals();
  }
});
