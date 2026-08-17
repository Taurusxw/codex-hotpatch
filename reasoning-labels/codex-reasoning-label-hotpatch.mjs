import { pathToFileURL } from 'node:url';

import { createCodexDevToolsTransport } from '../shared/codex-devtools-transport.mjs';

export const patchVersion = '1.0.9';

export function installInRenderer(version) {
  const labels = [
    ['轻度', '轻度（1/6 · Light）'],
    ['中', '中（2/6 · Medium）'],
    ['高', '高（3/6 · High）'],
    ['极高', '极高（4/6 · Extra High）'],
    ['最高', '最高（5/6 · Max）'],
    ['极高', '超高（6/6 · Ultra）'],
  ];
  const slotLabels = [
    ['composer.mode.local.reasoning.low.label', labels[0]],
    ['composer.mode.local.reasoning.medium.label', labels[1]],
    ['composer.mode.local.reasoning.high.label', labels[2]],
    ['composer.mode.local.reasoning.xhigh.label', labels[3]],
    ['composer.mode.local.reasoning.max.label', labels[4]],
    ['composer.mode.local.reasoning.ultra.label', labels[5]],
  ];

  const previous = window.__codexReasoningLabelHotpatch;
  if (previous?.version === version) {
    previous.apply();
    return { installed: true, version, reused: true, replacements: previous.replacements };
  }
  previous?.disconnect?.();

  let scheduled = false;
  let replacements = 0;
  let menuMatches = 0;
  let patchedLabels = 0;
  let maxPatchedLabels = 0;
  const scopes = new Set();

  function textNodes(root) {
    const nodes = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) nodes.push(walker.currentNode);
    return nodes;
  }

  function normalized(value) {
    return (value || '').replace(/\s+/g, ' ').trim();
  }

  function leafTexts(root) {
    return textNodes(root).map((node) => normalized(node.nodeValue)).filter(Boolean);
  }

  function looksLikeReasoningMenu(root) {
    const texts = leafTexts(root);
    if (!texts.includes('推理强度')) return false;
    let matchedSlots = 0;
    for (const [, [original, patched]] of slotLabels) {
      if (texts.includes(original) || texts.includes(patched)) matchedSlots += 1;
    }
    return matchedSlots >= 4;
  }

  function collectScopes() {
    scopes.clear();
    const selectors = [
      '[role="menu"]',
      '[role="listbox"]',
      '[data-radix-popper-content-wrapper]',
      '[data-radix-menu-content]',
    ].join(',');
    for (const candidate of document.querySelectorAll(selectors)) {
      if (looksLikeReasoningMenu(candidate)) scopes.add(candidate);
    }

    for (const node of textNodes(document.body)) {
      if (normalized(node.nodeValue) !== '推理强度') continue;
      let candidate = node.parentElement;
      for (let depth = 0; candidate && depth < 7; depth += 1, candidate = candidate.parentElement) {
        if (looksLikeReasoningMenu(candidate)) {
          scopes.add(candidate);
          break;
        }
      }
    }
  }

  function replaceMenuLabels(scope) {
    const nodes = textNodes(scope);
    const texts = nodes.map((node) => normalized(node.nodeValue));
    const extraHighIndex = texts.indexOf('极高');
    const ultraIndex = texts.lastIndexOf('极高');

    for (let index = 0; index < nodes.length; index += 1) {
      const node = nodes[index];
      const value = texts[index];
      let replacement = null;
      if (value === '轻度') replacement = labels[0][1];
      else if (value === '中') replacement = labels[1][1];
      else if (value === '高') replacement = labels[2][1];
      else if (value === '最高') replacement = labels[4][1];
      else if (value === '极高' && index === extraHighIndex) replacement = labels[3][1];
      else if (value === '极高' && index === ultraIndex) replacement = labels[5][1];

      if (replacement && value !== replacement) {
        node.nodeValue = node.nodeValue.replace(value, replacement);
        node.parentElement?.setAttribute('data-codex-reasoning-label-hotpatch', 'true');
        replacements += 1;
      }
    }
  }

  function apply() {
    scheduled = false;
    collectScopes();
    for (const scope of scopes) replaceMenuLabels(scope);
    const patchedValues = new Set(labels.map(([, patched]) => patched));
    const patchedNodes = new Set();
    for (const scope of scopes) {
      for (const node of textNodes(scope)) {
        if (patchedValues.has(normalized(node.nodeValue))) patchedNodes.add(node);
      }
    }
    menuMatches = scopes.size;
    patchedLabels = patchedNodes.size;
    maxPatchedLabels = Math.max(maxPatchedLabels, patchedLabels);
    api.replacements = replacements;
    api.menuMatches = menuMatches;
    api.patchedLabels = patchedLabels;
    api.maxPatchedLabels = maxPatchedLabels;
    api.lastAppliedAt = Date.now();
  }

  function scheduleApply() {
    if (scheduled) return;
    scheduled = true;
    queueMicrotask(apply);
  }

  function restore() {
    observer.disconnect();
    for (const node of textNodes(document.body)) {
      const value = normalized(node.nodeValue);
      for (const [original, patched] of labels) {
        if (value === patched) node.nodeValue = node.nodeValue.replace(value, original);
      }
    }
    for (const element of document.querySelectorAll('[data-codex-reasoning-label-hotpatch]')) {
      element.removeAttribute('data-codex-reasoning-label-hotpatch');
    }
    delete window.__codexReasoningLabelHotpatch;
  }

  const observer = new MutationObserver(scheduleApply);
  const api = {
    version,
    replacements,
    menuMatches,
    patchedLabels,
    maxPatchedLabels,
    lastAppliedAt: 0,
    apply,
    disconnect() { observer.disconnect(); },
    restore,
  };
  window.__codexReasoningLabelHotpatch = api;
  observer.observe(document.documentElement, {
    subtree: true,
    childList: true,
    characterData: true,
    attributes: true,
    attributeFilter: ['data-state', 'aria-hidden', 'inert'],
  });
  apply();
  return { installed: true, version, reused: false, replacements: api.replacements };
}

export function removeFromRenderer() {
  const patch = window.__codexReasoningLabelHotpatch;
  if (!patch) return { installed: false, removed: false };
  patch.restore();
  return { installed: false, removed: true };
}

export function statusInRenderer() {
  const patch = window.__codexReasoningLabelHotpatch;
  return patch
    ? {
      installed: true,
      version: patch.version,
      verification: patch.maxPatchedLabels >= 6
        ? 'six-labels-verified'
        : (patch.menuMatches > 0 ? 'partial-menu-match' : 'waiting-for-menu'),
      menuMatches: patch.menuMatches,
      patchedLabels: patch.patchedLabels,
      maxPatchedLabels: patch.maxPatchedLabels,
      replacements: patch.replacements,
      lastAppliedAt: patch.lastAppliedAt,
    }
    : { installed: false };
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
      'Usage: node codex-reasoning-label-hotpatch.mjs <--version|--once|--watch-port|--status|--remove> [port]',
    );
  }

  const { getTargets, evaluate, runForTargets } = createCodexDevToolsTransport({
    port,
    commandTimeoutMs: 4000,
    targetFilter: (target) =>
      target.type === 'page'
      && target.url?.startsWith('app://-/index.html')
      && target.webSocketDebuggerUrl,
  });
  const installExpression = `(${installInRenderer.toString()})(${JSON.stringify(patchVersion)})`;
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
    while (failures < 3) {
      try {
        const targets = await getTargets();
        failures = 0;
        for (const target of targets) {
          if (!injected.has(target.id)) {
            await evaluate(target, installExpression);
            injected.add(target.id);
          }
        }
      } catch {
        failures += 1;
      }
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
  }
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) await main();
