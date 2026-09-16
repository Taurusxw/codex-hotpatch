import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { createCompletionEvidenceIndex } from './completion-evidence.mjs';
import { createCodexDevToolsTransport } from '../shared/codex-devtools-transport.mjs';

export const patchVersion = '1.3.22';
const codexRoot = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
const sessionRoots = [
  path.join(codexRoot, 'sessions'),
  path.join(codexRoot, 'archived_sessions'),
];
const localAppData = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
const completionCachePath = path.join(
  localAppData,
  'OpenAI',
  'Codex',
  'hotpatches',
  'subagent-status',
  'completion-evidence-cache.json',
);
const completionEvidenceOptions = {
  cachePath: completionCachePath,
  agentMetadataDatabasePath: path.join(codexRoot, 'state_5.sqlite'),
};

export function installInRenderer(initialEvidence, version) {
  const settleTimeoutMs = 5000;
  const itemSpacingMs = 50;
  const rendererYieldTimeoutMs = 150;
  const maxItemsPerOpen = 128;
  const maxShowMoreClicks = 20;
  const maxContinuationPasses = 8;
  const activeHeadingPattern = /^(?:已开启|Active|Running)\s*[·•]\s*(\d+)$/i;
  const completedHeadingPattern = /^(?:完成|Completed)\s*[·•]\s*(\d+)$/i;
  const openLabels = ['打开子代理', '打开子智能体', 'Open subagents', 'Open sub-agents'];
  const backLabels = ['返回子代理列表', '返回子智能体列表', 'Back to subagents', 'Back to sub-agents'];

  const previous = window.__codexSubagentStatusHotpatch;
  if (previous?.version === version) {
    previous.updateEvidence(initialEvidence);
    return previous.status(true);
  }
  previous?.disconnect?.();

  let disabled = false;
  let processing = false;
  let startTimer = null;
  let projectionTimer = null;
  let panelProbeTimer = null;
  let lastVisiblePanelId = null;
  let pendingReason = null;
  let activeController = null;
  let interactionEpoch = 0;
  let continuationPasses = 0;
  let panelOpenCount = 0;
  let openedCount = 0;
  let repairedCount = 0;
  let abortedCount = 0;
  let lastRunAt = 0;
  let lastReason = 'installed-idle';
  let lastError = null;
  let completionEvidence = new Set(initialEvidence?.ids || []);
  let evidenceRevision = initialEvidence?.revision || 0;
  let evidenceUpdatedAt = initialEvidence?.updatedAt || 0;
  let lastVerifiedCandidates = 0;
  let lastSkippedUnverified = 0;
  let lastUnidentified = 0;
  let lastUnidentifiedLabels = [];
  let lastMetadataResolvedIds = [];
  let lastOpenedIds = [];
  let projectionRuns = 0;
  let projectedCompletedCount = 0;
  let lastProjectedIds = [];
  let lastProjectionReason = 'not-run';
  let lastProjectionAt = 0;
  let summaryProjectionRuns = 0;
  let projectedSummaryCompletedCount = 0;
  let lastProjectedSummaryIds = [];
  let lastSummaryProjectionAt = 0;
  let agentMetadataError = initialEvidence?.agentMetadataError || null;
  const projectedAgents = new Map();
  const projectedSummaryLabels = new Map();
  let agentMetadata = normalizeAgentMetadata(initialEvidence?.agents);

  function normalized(value) {
    return (value || '').replace(/\s+/g, ' ').trim();
  }

  function normalizedLookup(value) {
    return normalized(value)
      .toLocaleLowerCase()
      .replace(/[_-]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  function normalizeAgentMetadata(records) {
    const exactId = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    const result = new Map();
    for (const record of records || []) {
      const conversationId = record?.conversationId?.toLowerCase?.() || '';
      const parentConversationId = record?.parentConversationId?.toLowerCase?.() || '';
      if (!exactId.test(conversationId) || !exactId.test(parentConversationId)) continue;
      result.set(conversationId, {
        conversationId,
        parentConversationId,
        agentPath: typeof record.agentPath === 'string' ? record.agentPath : '',
        agentNickname: typeof record.agentNickname === 'string' ? record.agentNickname : '',
      });
    }
    return result;
  }

  function metadataDisplayLabel(record) {
    const leaf = record?.agentPath?.split(/[\\/]/).filter(Boolean).at(-1) || '';
    return normalizedLookup(leaf);
  }

  function buttonStartsWithLabel(buttonText, label) {
    const normalizedButton = normalizedLookup(buttonText);
    const normalizedLabel = normalizedLookup(label);
    return Boolean(normalizedLabel)
      && (normalizedButton === normalizedLabel
        || normalizedButton.startsWith(`${normalizedLabel} `));
  }

  function isVisible(element) {
    return Boolean(element?.isConnected && element.getClientRects().length);
  }

  function isSubagentArray(value) {
    return Array.isArray(value) && value.some((agent) =>
      typeof agent?.conversationId === 'string'
      && typeof agent?.parentConversationId === 'string'
      && typeof agent?.status === 'string',
    );
  }

  function collectNestedSubagentArrays(value, arrays, visitedValues, depth = 0) {
    if (!value || typeof value !== 'object' || depth > 4 || visitedValues.has(value)) return;
    visitedValues.add(value);
    if (isSubagentArray(value)) {
      if (!arrays.includes(value)) arrays.push(value);
      return;
    }
    if (Array.isArray(value)) {
      if (value.length <= 32) {
        for (const item of value) {
          if (item?.props || item?.children) {
            collectNestedSubagentArrays(item, arrays, visitedValues, depth + 1);
          }
        }
      }
      return;
    }
    for (const key of [
      'backgroundAgents',
      'subagents',
      'agents',
      'children',
      'props',
      'data',
      'item',
    ]) {
      if (key in value) {
        collectNestedSubagentArrays(value[key], arrays, visitedValues, depth + 1);
      }
    }
  }

  function collectCandidateSubagentArrays(candidate, visitedFibers = new Set()) {
    const arrays = [];
    const visitedValues = new Set();
    const fiberKey = Object.keys(candidate).find((key) => key.startsWith('__reactFiber$'));
    let fiber = fiberKey ? candidate[fiberKey] : null;
    for (let depth = 0; fiber && depth < 50; depth += 1, fiber = fiber.return) {
      if (visitedFibers.has(fiber)) continue;
      visitedFibers.add(fiber);
      for (const props of [fiber.memoizedProps, fiber.pendingProps]) {
        if (!props || typeof props !== 'object') continue;
        for (const value of Object.values(props)) {
          collectNestedSubagentArrays(value, arrays, visitedValues);
        }
      }
    }
    return arrays;
  }

  function summaryControls() {
    const controls = [];
    for (const control of document.querySelectorAll('button,[role="button"]')) {
      if (isVisible(control) && openLabels.includes(normalized(control.getAttribute('aria-label')))) {
        controls.push(control);
      }
    }
    for (const control of document.querySelectorAll(
      '[data-slot="thread-summary-panel-item-button"]',
    )) {
      if (isVisible(control)
          && !controls.includes(control)
          && collectCandidateSubagentArrays(control).length) {
        controls.push(control);
      }
    }
    return controls;
  }

  function collectSubagentArrays(initialControls = null) {
    const arrays = [];
    const candidates = initialControls ? [...initialControls] : summaryControls();
    for (const button of document.querySelectorAll(
      '[data-slot="thread-summary-panel-item-group"] > button',
    )) {
      if (isVisible(button)) candidates.push(button);
    }

    const visitedFibers = new Set();
    for (const candidate of candidates) {
      for (const value of collectCandidateSubagentArrays(candidate, visitedFibers)) {
        if (!arrays.includes(value)) arrays.push(value);
      }
    }
    return arrays;
  }

  function summaryTexts(label, meta, activeCount, totalCount) {
    const record = projectedSummaryLabels.get(label);
    const original = [
      record?.originalText || normalized(label.textContent),
      record?.metaOriginalText || normalized(meta?.textContent),
    ].join(' ');
    const english = /^en\b/i.test(document.documentElement?.lang || '')
      || /\b(?:active|running|done|completed)\b/i.test(original);
    const completedCount = Math.max(totalCount - activeCount, 0);
    return {
      label: activeCount > 0
        ? (english ? `${activeCount} running` : `${activeCount} 个运行中`)
        : (english ? `${totalCount} done` : `${totalCount} 完成`),
      meta: activeCount > 0 && completedCount > 0
        ? (english ? `${completedCount} done` : `${completedCount} 完成`)
        : '',
    };
  }

  function restoreSummaryLabel(label) {
    const record = projectedSummaryLabels.get(label);
    if (!record) return;
    if (label.textContent === record.projectedText) label.textContent = record.originalText;
    if (record.meta?.textContent === record.metaProjectedText) {
      record.meta.textContent = record.metaOriginalText;
    }
    projectedSummaryLabels.delete(label);
  }

  function reconcileSummaryLabels() {
    summaryProjectionRuns += 1;
    lastSummaryProjectionAt = Date.now();
    const visibleLabels = new Set();
    const projectedIds = new Set();

    for (const control of summaryControls()) {
      const label = control.querySelector?.('[data-slot="thread-summary-panel-item-label"]');
      if (!label) continue;
      const meta = control.querySelector?.('[data-slot="thread-summary-panel-item-meta"]') || null;
      visibleLabels.add(label);

      const agentsById = new Map();
      for (const agents of collectCandidateSubagentArrays(control)) {
        for (const agent of agents) {
          const id = agent?.conversationId?.toLowerCase() || null;
          if (id && !agentsById.has(id)) agentsById.set(id, agent);
        }
      }
      const agents = [...agentsById.values()];
      const verifiedIds = agents
        .map((agent) => agent?.conversationId?.toLowerCase() || null)
        .filter((id) => id && completionEvidence.has(id));
      if (!verifiedIds.length) {
        restoreSummaryLabel(label);
        continue;
      }

      for (const id of verifiedIds) projectedIds.add(id);
      const activeCount = agents.filter((agent) => agent?.status !== 'done').length;
      const projected = summaryTexts(label, meta, activeCount, agents.length);
      let record = projectedSummaryLabels.get(label);
      if (!record) {
        record = {
          originalText: label.textContent,
          projectedText: projected.label,
          meta,
          metaOriginalText: meta?.textContent || '',
          metaProjectedText: projected.meta,
        };
        projectedSummaryLabels.set(label, record);
      } else {
        record.projectedText = projected.label;
        record.metaProjectedText = projected.meta;
      }
      if (label.textContent !== projected.label) label.textContent = projected.label;
      if (meta && meta.textContent !== projected.meta) meta.textContent = projected.meta;
    }

    for (const label of projectedSummaryLabels.keys()) {
      if (!visibleLabels.has(label) && label?.isConnected === false) {
        projectedSummaryLabels.delete(label);
      }
    }
    lastProjectedSummaryIds = [...projectedIds].sort().slice(0, maxItemsPerOpen);
    projectedSummaryCompletedCount = projectedIds.size;
  }

  function reconcileProjectedStatuses(reason) {
    projectionRuns += 1;
    lastProjectionReason = reason;
    lastProjectionAt = Date.now();
    const summaryControlList = summaryControls();
    const subagentArrays = collectSubagentArrays(summaryControlList);
    const currentAgents = new Set();
    for (const subagents of subagentArrays) {
      for (const agent of subagents) currentAgents.add(agent);
    }

    for (const [agent, originalStatus] of projectedAgents) {
      const id = agent?.conversationId?.toLowerCase() || null;
      if (id && completionEvidence.has(id)) continue;
      if (agent?.status === 'done') agent.status = originalStatus;
      projectedAgents.delete(agent);
    }

    for (const subagents of subagentArrays) {
      for (const agent of subagents) {
        const id = agent?.conversationId?.toLowerCase() || null;
        if (!id || !completionEvidence.has(id) || agent.status === 'done') continue;
        if (!projectedAgents.has(agent)) projectedAgents.set(agent, agent.status);
        agent.status = 'done';
      }
    }

    const projectedIds = new Set();
    for (const agent of currentAgents) {
      const id = agent?.conversationId?.toLowerCase() || null;
      if (id && completionEvidence.has(id) && agent.status === 'done') projectedIds.add(id);
    }
    lastProjectedIds = [...projectedIds].sort().slice(0, maxItemsPerOpen);
    projectedCompletedCount = projectedIds.size;
    reconcileSummaryLabels();
    return projectedCompletedCount;
  }

  function restoreProjectedStatuses() {
    for (const [agent, originalStatus] of projectedAgents) {
      if (agent?.status === 'done') agent.status = originalStatus;
    }
    projectedAgents.clear();
    projectedCompletedCount = 0;
    lastProjectedIds = [];
    for (const label of [...projectedSummaryLabels.keys()]) restoreSummaryLabel(label);
    projectedSummaryCompletedCount = 0;
    lastProjectedSummaryIds = [];
  }

  function panelId() {
    for (const tab of document.querySelectorAll('[data-tab-id^="subagents:"]')) {
      if (isVisible(tab)) {
        return tab.getAttribute('data-tab-id')?.slice('subagents:'.length) || null;
      }
    }
    return null;
  }

  function headingInfo(pattern) {
    for (const heading of document.querySelectorAll('h2')) {
      const match = normalized(heading.textContent).match(pattern);
      if (match && isVisible(heading)) return { heading, count: Number(match[1]) };
    }
    return null;
  }

  function conversationId(button) {
    const propsKey = Object.keys(button).find((key) => key.startsWith('__reactProps$'));
    const props = propsKey ? button[propsKey] : null;
    const exactId = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    const fiberKey = Object.keys(button).find((key) => key.startsWith('__reactFiber$'));
    const buttonFiber = fiberKey ? button[fiberKey] : null;
    const expectedParent = panelId()?.toLowerCase() || null;

    const subagentsById = new Map();
    for (const candidate of collectCandidateSubagentArrays(button)) {
      for (const agent of candidate) {
        const id = agent?.conversationId?.toLowerCase() || null;
        if (id && !subagentsById.has(id)) subagentsById.set(id, agent);
      }
    }
    const subagents = [...subagentsById.values()];
    const allowedIds = new Set();
    const metadataCandidates = [];
    if (expectedParent && exactId.test(expectedParent)) {
      const ancestry = new Set([expectedParent]);
      for (let pass = 0; pass < subagents.length; pass += 1) {
        let changed = false;
        for (const agent of subagents) {
          const id = agent?.conversationId?.toLowerCase() || null;
          const parent = agent?.parentConversationId?.toLowerCase() || null;
          if (!exactId.test(id || '') || !ancestry.has(parent) || allowedIds.has(id)) continue;
          allowedIds.add(id);
          ancestry.add(id);
          changed = true;
        }
        if (!changed) break;
      }
      for (const record of agentMetadata.values()) {
        if (record.parentConversationId !== expectedParent) continue;
        metadataCandidates.push(record);
        allowedIds.add(record.conversationId);
      }
    } else {
      for (const record of agentMetadata.values()) {
        metadataCandidates.push(record);
        allowedIds.add(record.conversationId);
      }
    }
    if (!allowedIds.size) return null;

    const found = new Set();
    const inspectValue = (value, depth = 0) => {
      if (value == null || depth > 8) return;
      if (typeof value === 'string') {
        const id = value.toLowerCase();
        if (allowedIds.has(id)) found.add(id);
        return;
      }
      if (typeof value !== 'object') return;
      if (Array.isArray(value)) {
        for (const item of value) inspectValue(item, depth + 1);
        return;
      }
      for (const key of ['seed', 'conversationId', 'id']) {
        if (typeof value[key] === 'string') inspectValue(value[key], depth + 1);
      }
      if ('children' in value) inspectValue(value.children, depth + 1);
      if ('props' in value) inspectValue(value.props, depth + 1);
    };
    inspectValue(props);

    const pending = [buttonFiber];
    const visited = new Set();
    while (pending.length && visited.size < 80) {
      const fiber = pending.pop();
      if (!fiber || visited.has(fiber)) continue;
      visited.add(fiber);
      inspectValue(fiber.key);
      inspectValue(fiber.memoizedProps);
      inspectValue(fiber.pendingProps);
      if (fiber.child) pending.push(fiber.child);
      if (fiber.sibling && fiber.return !== buttonFiber?.return) pending.push(fiber.sibling);
    }
    if (found.size === 1) return [...found][0];
    if (found.size > 1) return null;

    const buttonText = normalized(button.innerText);
    const nameMatches = subagents.filter((agent) => {
      const parent = agent?.parentConversationId?.toLowerCase() || null;
      const id = agent?.conversationId?.toLowerCase() || null;
      const displayName = normalized(agent?.displayName);
      return allowedIds.has(id)
        && displayName
        && (buttonText === displayName || buttonText.startsWith(`${displayName} `));
    });
    const matchedIds = new Set(nameMatches.map((agent) => agent.conversationId.toLowerCase()));
    const metadataMatches = metadataCandidates.filter((record) => {
      const displayLabel = metadataDisplayLabel(record);
      if (displayLabel && buttonStartsWithLabel(buttonText, displayLabel)) return true;
      return !displayLabel
        && record.agentNickname
        && buttonStartsWithLabel(buttonText, record.agentNickname);
    });
    for (const record of metadataMatches) matchedIds.add(record.conversationId);
    if (matchedIds.size === 1) {
      const [id] = matchedIds;
      if (metadataMatches.some((record) => record.conversationId === id)) {
        if (!lastMetadataResolvedIds.includes(id)) lastMetadataResolvedIds.push(id);
      }
      return id;
    }
    return null;
  }

  function eligibleItem(section, attempted, observed, skipped, unidentified) {
    const group = section.querySelector('[data-slot="thread-summary-panel-item-group"]');
    if (!group) return null;
    for (const button of group.querySelectorAll(':scope > button')) {
      if (!isVisible(button)) continue;
      const id = conversationId(button);
      if (!id) {
        unidentified.add(normalized(button.innerText).slice(0, 120));
        continue;
      }
      observed.add(id);
      if (attempted.has(id)) continue;
      if (!completionEvidence.has(id)) {
        skipped.add(id);
        continue;
      }
      return { button, id };
    }
    return null;
  }

  function showMoreButton(section) {
    let root = section;
    for (let depth = 0; root && root !== document.body && depth < 7; depth += 1) {
      const match = [...root.querySelectorAll('button')].find((button) =>
        isVisible(button) && /^(?:再显示|显示更多|Show more|Load more)/i.test(normalized(button.innerText)),
      );
      if (match) return match;
      root = root.parentElement;
    }
    return null;
  }

  function backButton() {
    return [...document.querySelectorAll('button')].find((button) =>
      isVisible(button) && backLabels.includes(normalized(button.getAttribute('aria-label'))),
    );
  }

  function hasBlockingDialog() {
    return [...document.querySelectorAll('[role="dialog"]')].some(isVisible);
  }

  function abortActive(reason) {
    if (!activeController || activeController.signal.aborted) return;
    lastReason = reason;
    abortedCount += 1;
    activeController.abort(reason);
  }

  async function waitFor(getValue, signal, timeoutMs = settleTimeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (!disabled && !signal.aborted && Date.now() < deadline) {
      const value = getValue();
      if (value) return value;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    return null;
  }

  async function yieldToRenderer(signal) {
    if (signal.aborted || disabled) return;
    await new Promise((resolve) => {
      if ('requestIdleCallback' in window) {
        window.requestIdleCallback(resolve, { timeout: rendererYieldTimeoutMs });
      } else {
        setTimeout(resolve, 25);
      }
    });
    if (!signal.aborted && !disabled) {
      await new Promise((resolve) => setTimeout(resolve, itemSpacingMs));
    }
  }

  async function refreshVisibleList(trigger) {
    if (processing || disabled) return;
    reconcileProjectedStatuses(`refresh:${trigger}`);
    processing = true;
    activeController = new AbortController();
    const { signal } = activeController;
    lastRunAt = Date.now();
    lastError = null;
    lastReason = trigger;
    const attempted = new Set();
    const observed = new Set();
    const skipped = new Set();
    const unidentified = new Set();
    lastMetadataResolvedIds = [];
    let showMoreClicks = 0;
    let processedThisRun = 0;
    let expectedPanelId = null;
    const runEpoch = interactionEpoch;
    lastOpenedIds = [];

    try {
      if (hasBlockingDialog()) {
        lastReason = 'blocked-by-dialog';
        return;
      }

      const initialActive = await waitFor(() => headingInfo(activeHeadingPattern), signal, 2500);
      if (!initialActive) {
        lastReason = 'panel-not-open';
        return;
      }
      if (initialActive.count < 1) {
        lastReason = 'nothing-to-repair';
        return;
      }
      expectedPanelId = panelId();
      lastVisiblePanelId = expectedPanelId || 'visible-panel-without-id';

      while (!disabled && !signal.aborted && processedThisRun < maxItemsPerOpen) {
        if (document.hidden) {
          abortActive('page-hidden');
          break;
        }
        if (hasBlockingDialog()) {
          abortActive('blocked-by-dialog');
          break;
        }
        if (expectedPanelId && panelId() !== expectedPanelId) {
          abortActive('panel-changed');
          break;
        }

        const active = headingInfo(activeHeadingPattern);
        if (!active || active.count < 1) {
          lastReason = 'completed';
          break;
        }
        const section = active.heading.closest('section');
        if (!section) {
          lastReason = 'active-section-missing';
          break;
        }

        const candidate = eligibleItem(section, attempted, observed, skipped, unidentified);
        if (!candidate) {
          const showMore = showMoreButton(section);
          if (showMore && showMoreClicks < maxShowMoreClicks) {
            await yieldToRenderer(signal);
            if (signal.aborted) break;
            showMore.click();
            showMoreClicks += 1;
            await new Promise((resolve) => setTimeout(resolve, 250));
            continue;
          }
          lastReason = showMore
            ? 'show-more-budget'
            : (skipped.size || unidentified.size ? 'unverified-items-skipped' : 'all-visible-items-checked');
          break;
        }

        await yieldToRenderer(signal);
        if (signal.aborted || disabled) break;
        if (conversationId(candidate.button) !== candidate.id || !completionEvidence.has(candidate.id)) {
          attempted.add(candidate.id);
          skipped.add(candidate.id);
          continue;
        }

        const beforeActive = active.count;
        const beforeCompleted = headingInfo(completedHeadingPattern)?.count || 0;
        attempted.add(candidate.id);
        candidate.button.click();
        lastOpenedIds.push(candidate.id);
        openedCount += 1;
        processedThisRun += 1;

        const back = await waitFor(backButton, signal);
        if (!back) {
          if (signal.aborted) break;
          lastError = `无法返回子智能体列表：${candidate.id}`;
          lastReason = 'back-button-timeout';
          break;
        }
        if (disabled || signal.aborted) break;
        back.click();

        const returned = await waitFor(() => headingInfo(activeHeadingPattern), signal);
        if (!returned) {
          if (signal.aborted) break;
          lastError = `子智能体列表未恢复：${candidate.id}`;
          lastReason = 'list-return-timeout';
          break;
        }

        const afterActive = returned.count;
        const afterCompleted = headingInfo(completedHeadingPattern)?.count || 0;
        const repaired = Math.max(beforeActive - afterActive, afterCompleted - beforeCompleted, 0);
        repairedCount += repaired;
      }

      if (processedThisRun >= maxItemsPerOpen) lastReason = 'per-open-safety-budget';
    } catch (error) {
      if (!signal.aborted) {
        lastError = error?.message || String(error);
        lastReason = 'unexpected-error';
      }
    } finally {
      lastVerifiedCandidates = attempted.size;
      lastSkippedUnverified = skipped.size;
      lastUnidentified = unidentified.size;
      lastUnidentifiedLabels = [...unidentified].slice(0, 20);
      lastMetadataResolvedIds = lastMetadataResolvedIds.slice(0, 20);
      processing = false;
      lastRunAt = Date.now();
      activeController = null;
      const queuedReason = pendingReason;
      pendingReason = null;
      const panelStillOpen = Boolean(headingInfo(activeHeadingPattern))
        && (!expectedPanelId || panelId() === expectedPanelId);
      const canContinue = !disabled && runEpoch === interactionEpoch && panelStillOpen;
      if (canContinue
        && ['show-more-budget', 'per-open-safety-budget'].includes(lastReason)
        && continuationPasses < maxContinuationPasses) {
        continuationPasses += 1;
        scheduleRefresh('background-continuation', 800);
      } else if (!disabled && runEpoch === interactionEpoch && queuedReason) {
        scheduleRefresh(queuedReason, 500);
      }
    }
  }

  function cancelScheduled() {
    if (startTimer) clearTimeout(startTimer);
    startTimer = null;
    pendingReason = null;
  }

  function scheduleRefresh(reason, delayMs = 0) {
    if (disabled) return;
    if (processing) {
      pendingReason = reason;
      return;
    }
    if (startTimer) clearTimeout(startTimer);
    const scheduledEpoch = interactionEpoch;
    startTimer = setTimeout(() => {
      startTimer = null;
      if (disabled || scheduledEpoch !== interactionEpoch) return;
      void refreshVisibleList(reason);
    }, delayMs);
  }

  function scheduleProjection(reason, delayMs = 100) {
    if (disabled) return;
    if (projectionTimer) clearTimeout(projectionTimer);
    const scheduledEpoch = interactionEpoch;
    projectionTimer = setTimeout(() => {
      projectionTimer = null;
      if (disabled || scheduledEpoch !== interactionEpoch) return;
      reconcileProjectedStatuses(reason);
    }, delayMs);
  }

  function scheduleAfterPanelOpen() {
    if (disabled) return;
    cancelScheduled();
    if (processing) abortActive('new-panel-open');
    panelOpenCount += 1;
    continuationPasses = 0;
    scheduleRefresh('user-opened-panel');
  }

  function checkPanelVisibility() {
    if (disabled || document.hidden) return;
    if (!headingInfo(activeHeadingPattern)) {
      lastVisiblePanelId = null;
      return;
    }
    const visiblePanelId = panelId() || 'visible-panel-without-id';
    if (visiblePanelId === lastVisiblePanelId) return;
    lastVisiblePanelId = visiblePanelId;
    reconcileProjectedStatuses('panel-became-visible');
    panelOpenCount += 1;
    continuationPasses = 0;
    scheduleRefresh('panel-became-visible');
  }

  function onDocumentClick(event) {
    const control = event.target instanceof Element
      ? event.target.closest('button,[role="button"]')
      : null;
    const label = normalized(control?.getAttribute('aria-label'));
    if (control && openLabels.includes(label)) {
      reconcileProjectedStatuses('pre-open-click');
      scheduleAfterPanelOpen();
      return;
    }
    if (event.isTrusted) {
      interactionEpoch += 1;
      cancelScheduled();
      if (processing) abortActive('user-interaction');
      scheduleProjection('post-user-interaction');
      scheduleRefresh('post-user-interaction-resume', 2000);
    }
  }

  function onDocumentKeydown(event) {
    if (event.isTrusted) {
      interactionEpoch += 1;
      cancelScheduled();
      if (processing) abortActive('user-interaction');
      scheduleProjection('post-user-interaction');
      scheduleRefresh('post-user-interaction-resume', 2000);
    }
  }

  function onVisibilityChange() {
    if (disabled || document.hidden || !headingInfo(activeHeadingPattern)) return;
    scheduleProjection('page-visible');
    scheduleRefresh('page-visible-resume', 500);
  }

  function status(reused = false) {
    return {
      installed: !disabled,
      version,
      reused,
      trigger: 'event-driven-projection-and-resumable-detail-migration',
      filter: 'bounded-react-agent-array-readonly-state-metadata-and-latest-task-complete',
      observerInstalled: false,
      panelProbeInstalled: Boolean(panelProbeTimer),
      processing,
      completionEvidenceCount: completionEvidence.size,
      evidenceRevision,
      evidenceUpdatedAt,
      panelOpenCount,
      openedCount,
      repairedCount,
      abortedCount,
      lastVerifiedCandidates,
      lastSkippedUnverified,
      lastUnidentified,
      lastUnidentifiedLabels,
      lastMetadataResolvedIds,
      agentMetadataCount: agentMetadata.size,
      agentMetadataError,
      continuationPasses,
      lastOpenedIds,
      projectionRuns,
      projectedCompletedCount,
      lastProjectedIds,
      lastProjectionReason,
      lastProjectionAt,
      summaryProjectionRuns,
      projectedSummaryCompletedCount,
      lastProjectedSummaryIds,
      lastSummaryProjectionAt,
      visibleActiveCount: headingInfo(activeHeadingPattern)?.count ?? null,
      visibleCompletedCount: headingInfo(completedHeadingPattern)?.count ?? null,
      lastRunAt,
      lastReason,
      lastError,
    };
  }

  function disconnect() {
    disabled = true;
    cancelScheduled();
    if (projectionTimer) clearTimeout(projectionTimer);
    projectionTimer = null;
    if (panelProbeTimer) clearInterval(panelProbeTimer);
    panelProbeTimer = null;
    abortActive('disconnected');
    restoreProjectedStatuses();
    document.removeEventListener('click', onDocumentClick, true);
    document.removeEventListener('keydown', onDocumentKeydown, true);
    document.removeEventListener('visibilitychange', onVisibilityChange);
    delete window.__codexSubagentStatusHotpatch;
  }

  const api = {
    version,
    status,
    disconnect,
    updateEvidence(payload) {
      const nextEvidence = new Set(payload?.ids || []);
      const gainedCompletion = [...nextEvidence].some((id) => !completionEvidence.has(id));
      completionEvidence = nextEvidence;
      agentMetadata = normalizeAgentMetadata(payload?.agents);
      agentMetadataError = payload?.agentMetadataError || null;
      evidenceRevision = payload?.revision || 0;
      evidenceUpdatedAt = payload?.updatedAt || Date.now();
      reconcileProjectedStatuses('completion-evidence-updated');
      if (gainedCompletion && headingInfo(activeHeadingPattern)) {
        scheduleRefresh('completion-evidence-updated', 500);
      }
      return status(false);
    },
    repairNow() {
      if (!processing) void refreshVisibleList('manual-repair');
      return status(false);
    },
  };
  window.__codexSubagentStatusHotpatch = api;
  document.addEventListener('click', onDocumentClick, true);
  document.addEventListener('keydown', onDocumentKeydown, true);
  document.addEventListener('visibilitychange', onVisibilityChange);
  panelProbeTimer = setInterval(checkPanelVisibility, 1000);
  reconcileProjectedStatuses('install');
  checkPanelVisibility();
  return status(false);
}

export function updateEvidenceInRenderer(payload) {
  const patch = window.__codexSubagentStatusHotpatch;
  return patch?.updateEvidence(payload) || { installed: false };
}

export function removeFromRenderer() {
  const patch = window.__codexSubagentStatusHotpatch;
  if (!patch) return { installed: false, removed: false };
  patch.disconnect();
  return { installed: false, removed: true };
}

export function statusInRenderer() {
  const patch = window.__codexSubagentStatusHotpatch;
  return patch ? patch.status(false) : { installed: false };
}

function expressionWithPayload(callback, ...payloads) {
  const serialized = payloads
    .map((payload) => JSON.stringify(payload).replaceAll('<', '\\u003c'))
    .join(',');
  return `(${callback.toString()})(${serialized})`;
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
      'Usage: node codex-subagent-status-hotpatch.mjs <--version|--once|--watch-port|--status|--remove> [port]',
    );
  }

  const { getTargets, evaluate, runForTargets } = createCodexDevToolsTransport({
    port,
    targetFilter: (target) =>
      target.type === 'page'
      && target.url === 'app://-/index.html'
      && target.webSocketDebuggerUrl,
  });
  const installExpression = (evidence) => expressionWithPayload(installInRenderer, evidence, patchVersion);
  const evidenceExpression = (evidence) => expressionWithPayload(updateEvidenceInRenderer, evidence);
  const removeExpression = `(${removeFromRenderer.toString()})()`;
  const statusExpression = `(${statusInRenderer.toString()})()`;

  if (mode === '--once') {
    const targets = await getTargets();
    const evidenceIndex = await createCompletionEvidenceIndex(
      sessionRoots,
      () => {},
      completionEvidenceOptions,
    );
    try {
      process.stdout.write(JSON.stringify({
        patchVersion,
        evidenceWatching: evidenceIndex.watching,
        targets: await runForTargets(installExpression(evidenceIndex.snapshot()), targets),
      }));
    } finally {
      await evidenceIndex.close();
    }
  } else if (mode === '--status') {
    process.stdout.write(JSON.stringify({ patchVersion, targets: await runForTargets(statusExpression) }));
  } else if (mode === '--remove') {
    process.stdout.write(JSON.stringify({ patchVersion, targets: await runForTargets(removeExpression) }));
  } else {
    const injected = new Set();
    let currentTargets = [];
    let failures = 0;
    let broadcastQueue = Promise.resolve();
    let evidenceIndex = null;

    async function ensureEvidenceIndex() {
      if (evidenceIndex) return evidenceIndex;
      evidenceIndex = await createCompletionEvidenceIndex(sessionRoots, (snapshot, reason) => {
        broadcastQueue = broadcastQueue.then(async () => {
          for (const target of currentTargets) {
            try {
              await evaluate(target, evidenceExpression(snapshot));
            } catch (error) {
              process.stderr.write(`${new Date().toISOString()} evidence update failed ${target.id}: ${error.message}\n`);
            }
          }
          process.stdout.write(`${new Date().toISOString()} evidence revision ${snapshot.revision} (${reason})\n`);
        }).catch((error) => {
          process.stderr.write(`${new Date().toISOString()} evidence broadcast failed: ${error.message}\n`);
        });
      }, completionEvidenceOptions);
      return evidenceIndex;
    }

    try {
      while (failures < 3) {
        let waitMs = 10000;
        try {
          currentTargets = await getTargets();
          failures = 0;
          const index = await ensureEvidenceIndex();
          const liveTargetIds = new Set(currentTargets.map((target) => target.id));
          for (const targetId of injected) {
            if (!liveTargetIds.has(targetId)) injected.delete(targetId);
          }
          for (const target of currentTargets) {
            if (!injected.has(target.id)) {
              await evaluate(target, installExpression(index.snapshot()));
              injected.add(target.id);
              process.stdout.write(`${new Date().toISOString()} injected ${target.id}\n`);
            }
          }
        } catch (error) {
          failures += 1;
          currentTargets = [];
          waitMs = Math.min(2000 * (2 ** (failures - 1)), 8000);
          process.stderr.write(`${new Date().toISOString()} ${error.message}\n`);
        }
        await new Promise((resolve) => setTimeout(resolve, waitMs));
      }
    } finally {
      await evidenceIndex?.close();
      await broadcastQueue;
    }
  }
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) await main();
