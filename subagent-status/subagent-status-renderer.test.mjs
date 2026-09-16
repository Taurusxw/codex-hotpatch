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

function installCurrentSummaryFixture(
  agents,
  labelText = '5 个运行中',
  initiallyVisible = true,
  metaText = '',
) {
  const listeners = new Map();
  const intervals = new Set();
  const previousSetInterval = globalThis.setInterval;
  const previousClearInterval = globalThis.clearInterval;
  const previousElement = Object.prototype.hasOwnProperty.call(globalThis, 'Element')
    ? { exists: true, value: globalThis.Element }
    : { exists: false };
  const previousWindow = Object.prototype.hasOwnProperty.call(globalThis, 'window')
    ? { exists: true, value: globalThis.window }
    : { exists: false };
  const previousDocument = Object.prototype.hasOwnProperty.call(globalThis, 'document')
    ? { exists: true, value: globalThis.document }
    : { exists: false };

  let visible = initiallyVisible;
  const label = { isConnected: true, textContent: labelText };
  const meta = { isConnected: true, textContent: metaText };
  const nestedProps = (currentAgents) => ({
    children: {
      props: { backgroundAgents: currentAgents },
    },
  });
  const fiber = {
    memoizedProps: nestedProps(agents),
    pendingProps: nestedProps(agents),
    return: null,
  };
  const opener = {
    isConnected: true,
    getClientRects() { return visible ? [{}] : []; },
    getAttribute(name) {
      return name === 'data-slot' ? 'thread-summary-panel-item-button' : null;
    },
    querySelector(selector) {
      if (selector === '[data-slot="thread-summary-panel-item-label"]') return label;
      if (selector === '[data-slot="thread-summary-panel-item-meta"]') return meta;
      return null;
    },
  };
  opener.__reactFiber$fixture = fiber;

  globalThis.setInterval = (callback) => {
    intervals.add(callback);
    return callback;
  };
  globalThis.clearInterval = (callback) => intervals.delete(callback);
  globalThis.Element = class {};
  globalThis.window = {};
  globalThis.document = {
    hidden: false,
    documentElement: { lang: 'zh-CN' },
    querySelectorAll(selector) {
      if (!visible) return [];
      if (selector === 'button,[role="button"]') return [opener];
      if (selector === '[data-slot="thread-summary-panel-item-button"]') return [opener];
      return [];
    },
    addEventListener(type, callback) { listeners.set(type, callback); },
    removeEventListener(type, callback) {
      if (listeners.get(type) === callback) listeners.delete(type);
    },
  };

  return {
    label,
    meta,
    listeners,
    runPanelProbes() {
      for (const callback of [...intervals]) callback();
    },
    setVisible(nextVisible) { visible = nextVisible; },
    triggerTrustedClick() {
      listeners.get('click')?.({ isTrusted: true, target: null });
    },
    setAgents(nextAgents) {
      fiber.memoizedProps = nestedProps(nextAgents);
      fiber.pendingProps = nestedProps(nextAgents);
    },
    restoreGlobals() {
      globalThis.setInterval = previousSetInterval;
      globalThis.clearInterval = previousClearInterval;
      if (previousElement.exists) globalThis.Element = previousElement.value;
      else delete globalThis.Element;
      if (previousWindow.exists) globalThis.window = previousWindow.value;
      else delete globalThis.window;
      if (previousDocument.exists) globalThis.document = previousDocument.value;
      else delete globalThis.document;
    },
  };
}

function installMetadataFallbackPanelFixture(parentConversationId, displayName) {
  const listeners = new Map();
  const intervals = new Set();
  const previousSetInterval = globalThis.setInterval;
  const previousClearInterval = globalThis.clearInterval;
  const previousWindow = Object.prototype.hasOwnProperty.call(globalThis, 'window')
    ? { exists: true, value: globalThis.window }
    : { exists: false };
  const previousDocument = Object.prototype.hasOwnProperty.call(globalThis, 'document')
    ? { exists: true, value: globalThis.document }
    : { exists: false };

  let detailOpen = false;
  let activeCount = 1;
  let completedCount = 0;
  const item = {
    isConnected: true,
    innerText: `${displayName} 9 天`,
    getClientRects() { return [{}]; },
    click() { detailOpen = true; },
  };
  const group = {
    querySelectorAll(selector) {
      return selector === ':scope > button' && activeCount > 0 ? [item] : [];
    },
  };
  const section = {
    parentElement: null,
    querySelector(selector) {
      return selector === '[data-slot="thread-summary-panel-item-group"]' ? group : null;
    },
    querySelectorAll() { return []; },
  };
  const activeHeading = {
    isConnected: true,
    get textContent() { return `Active · ${activeCount}`; },
    getClientRects() { return detailOpen ? [] : [{}]; },
    closest(selector) { return selector === 'section' ? section : null; },
  };
  const completedHeading = {
    isConnected: true,
    get textContent() { return `Completed · ${completedCount}`; },
    getClientRects() { return detailOpen ? [] : [{}]; },
    closest(selector) { return selector === 'section' ? section : null; },
  };
  const tab = {
    isConnected: true,
    getClientRects() { return detailOpen ? [] : [{}]; },
    getAttribute(name) {
      return name === 'data-tab-id' ? `subagents:${parentConversationId}` : null;
    },
  };
  const back = {
    isConnected: true,
    getClientRects() { return detailOpen ? [{}] : []; },
    getAttribute(name) { return name === 'aria-label' ? 'Back to subagents' : null; },
    click() {
      detailOpen = false;
      activeCount = 0;
      completedCount = 1;
    },
  };

  globalThis.setInterval = (callback) => {
    intervals.add(callback);
    return callback;
  };
  globalThis.clearInterval = (callback) => intervals.delete(callback);
  globalThis.window = {};
  globalThis.document = {
    hidden: false,
    body: {},
    documentElement: { lang: 'zh-CN' },
    querySelectorAll(selector) {
      if (selector === 'h2') return [activeHeading, completedHeading];
      if (selector === '[data-tab-id^="subagents:"]') return [tab];
      if (selector === 'button') return detailOpen ? [back] : [item];
      return [];
    },
    addEventListener(type, callback) { listeners.set(type, callback); },
    removeEventListener(type, callback) {
      if (listeners.get(type) === callback) listeners.delete(type);
    },
  };

  return {
    listeners,
    counts() { return { activeCount, completedCount }; },
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

test('installs, reuses, updates evidence, and removes the idle renderer patch', () => {
  const fixture = installIdleFixture();
  try {
    const installed = installInRenderer({ ids: ['a'], revision: 1, updatedAt: 10 }, 'fixture-version');
    assert.equal(installed.installed, true);
    assert.equal(installed.version, 'fixture-version');
    assert.equal(installed.completionEvidenceCount, 1);
    assert.equal(installed.panelProbeInstalled, true);
    assert.equal(fixture.listeners.size, 3);

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

test('does not rerun full projection while probing the same visible legacy panel', () => {
  const fixture = installPanelProbeFixture(true);
  try {
    const installed = installInRenderer({ ids: [], revision: 1, updatedAt: 10 }, 'legacy-panel-version');
    assert.equal(installed.projectionRuns, 2);
    assert.equal(installed.lastProjectionReason, 'panel-became-visible');

    fixture.runPanelProbes();
    const status = statusInRenderer();
    assert.equal(status.projectionRuns, 2);
    assert.equal(status.lastProjectionReason, 'panel-became-visible');
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
    assert.equal(fixture.meta.textContent, '4 完成');
    assert.equal(installed.projectedSummaryCompletedCount, 4);

    const rehydratedAgents = createAgents();
    fixture.setAgents(rehydratedAgents);
    const updated = updateEvidenceInRenderer({ ids, revision: 2, updatedAt: 20 });
    assert.deepEqual(rehydratedAgents.map((agent) => agent.status), [
      'done', 'done', 'done', 'done', 'done',
    ]);
    assert.equal(fixture.label.textContent, '5 完成');
    assert.equal(fixture.meta.textContent, '');
    assert.equal(updated.projectedSummaryCompletedCount, 5);

    assert.deepEqual(removeFromRenderer(), { installed: false, removed: true });
    assert.deepEqual(rehydratedAgents.map((agent) => agent.status), [
      'running', 'running', 'running', 'running', 'running',
    ]);
    assert.equal(fixture.label.textContent, '5 个运行中');
    assert.equal(fixture.meta.textContent, '');
    assert.equal(fixture.listeners.size, 0);
  } finally {
    globalThis.window?.__codexSubagentStatusHotpatch?.disconnect?.();
    fixture.restoreGlobals();
  }
});

test('projects a summary that appears after navigation on the next trusted interaction', async () => {
  const id = '01a00700-0000-7000-8000-000000000002';
  const agent = {
    conversationId: id,
    parentConversationId: '019ff090-333b-7153-85fa-ee0d41351784',
    displayName: 'Late agent',
    status: 'running',
  };
  const fixture = installCurrentSummaryFixture([agent], '1 个运行中', false);
  try {
    const installed = installInRenderer({ ids: [id], revision: 1, updatedAt: 10 }, 'late-summary-version');
    assert.equal(installed.projectionRuns, 1);
    assert.equal(agent.status, 'running');

    fixture.setVisible(true);
    fixture.triggerTrustedClick();
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.equal(agent.status, 'done');
    assert.equal(fixture.label.textContent, '1 完成');
    assert.equal(fixture.meta.textContent, '');
    assert.equal(statusInRenderer().projectionRuns, 2);

    fixture.runPanelProbes();
    assert.equal(statusInRenderer().projectionRuns, 2);
  } finally {
    globalThis.window?.__codexSubagentStatusHotpatch?.disconnect?.();
    fixture.restoreGlobals();
  }
});

test('updates running and completed summary nodes as one coherent pair', () => {
  const parentConversationId = '019ff090-333b-7153-85fa-ee0d41351784';
  const agents = Array.from({ length: 12 }, (_, index) => ({
    conversationId: `01a00700-0000-7000-8000-${String(index).padStart(12, '0')}`,
    parentConversationId,
    displayName: `Agent ${index + 1}`,
    status: index < 8 ? 'done' : 'active',
  }));
  const completedIds = agents.slice(0, 11).map((agent) => agent.conversationId);
  const fixture = installCurrentSummaryFixture(agents, '4 个运行中', true, '8 完成');
  try {
    installInRenderer({ ids: completedIds, revision: 1, updatedAt: 10 }, 'paired-summary-version');
    assert.equal(fixture.label.textContent, '1 个运行中');
    assert.equal(fixture.meta.textContent, '11 完成');

    updateEvidenceInRenderer({
      ids: agents.map((agent) => agent.conversationId),
      revision: 2,
      updatedAt: 20,
    });
    assert.equal(fixture.label.textContent, '12 完成');
    assert.equal(fixture.meta.textContent, '');

    assert.deepEqual(removeFromRenderer(), { installed: false, removed: true });
    assert.equal(fixture.label.textContent, '4 个运行中');
    assert.equal(fixture.meta.textContent, '8 完成');
  } finally {
    globalThis.window?.__codexSubagentStatusHotpatch?.disconnect?.();
    fixture.restoreGlobals();
  }
});

test('repairs a completed legacy item by read-only state metadata when React no longer exposes ids', async () => {
  const parentConversationId = '019fb2f4-a18e-74c0-93d0-cafc91b0d28f';
  const conversationId = '019ffab3-c0c8-7cf1-941d-a990597e4cb5';
  const fixture = installMetadataFallbackPanelFixture(
    parentConversationId,
    'Space skill forward eval',
  );
  try {
    const installed = installInRenderer({
      ids: [conversationId],
      agents: [{
        conversationId,
        parentConversationId,
        agentPath: '/root/space_skill_forward_eval',
        agentNickname: 'Schrodinger',
      }],
      revision: 1,
      updatedAt: 10,
      agentMetadataError: null,
    }, 'metadata-fallback-version');
    assert.equal(installed.agentMetadataCount, 1);

    const deadline = Date.now() + 1500;
    while (statusInRenderer().repairedCount < 1 && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    const status = statusInRenderer();
    assert.equal(status.repairedCount, 1);
    assert.deepEqual(status.lastMetadataResolvedIds, [conversationId]);
    assert.deepEqual(status.lastOpenedIds, [conversationId]);
    assert.equal(status.lastUnidentified, 0);
    assert.deepEqual(fixture.counts(), { activeCount: 0, completedCount: 1 });
  } finally {
    globalThis.window?.__codexSubagentStatusHotpatch?.disconnect?.();
    fixture.restoreGlobals();
  }
});
