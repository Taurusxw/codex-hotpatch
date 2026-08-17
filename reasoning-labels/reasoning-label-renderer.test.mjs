import assert from 'node:assert/strict';
import test from 'node:test';

import {
  installInRenderer,
  removeFromRenderer,
  statusInRenderer,
} from './codex-reasoning-label-hotpatch.mjs';

const originals = ['推理强度', '轻度', '中', '高', '极高', '最高', '极高'];
const patched = [
  '推理强度',
  '轻度（1/6 · Light）',
  '中（2/6 · Medium）',
  '高（3/6 · High）',
  '极高（4/6 · Extra High）',
  '最高（5/6 · Max）',
  '超高（6/6 · Ultra）',
];

function createMenu(values = originals) {
  const elements = values.map(() => {
    const attributes = new Map();
    return {
      attributes,
      parentElement: null,
      setAttribute(name, value) { attributes.set(name, value); },
      removeAttribute(name) { attributes.delete(name); },
    };
  });
  const textNodes = values.map((value, index) => ({
    nodeValue: value,
    parentElement: elements[index],
  }));
  return { textNodes, elements };
}

function installFixture(initialMenus = []) {
  const menus = [...initialMenus];
  const observers = [];
  const body = {};
  const documentElement = {};
  const document = {
    body,
    documentElement,
    createTreeWalker(root) {
      const nodes = root === body ? menus.flatMap((menu) => menu.textNodes) : (root.textNodes || []);
      let index = -1;
      return {
        currentNode: null,
        nextNode() {
          index += 1;
          this.currentNode = nodes[index] || null;
          return Boolean(this.currentNode);
        },
      };
    },
    querySelectorAll(selector) {
      if (selector === '[data-codex-reasoning-label-hotpatch]') {
        return menus.flatMap((menu) => menu.elements)
          .filter((element) => element.attributes.has('data-codex-reasoning-label-hotpatch'));
      }
      return menus;
    },
  };
  class FakeMutationObserver {
    constructor(callback) {
      this.callback = callback;
      this.disconnected = false;
      observers.push(this);
    }

    observe(root, options) {
      this.root = root;
      this.options = options;
    }

    disconnect() {
      this.disconnected = true;
    }

    trigger() {
      this.callback([]);
    }
  }

  const previous = new Map();
  for (const [name, value] of Object.entries({
    window: {},
    document,
    NodeFilter: { SHOW_TEXT: 4 },
    MutationObserver: FakeMutationObserver,
  })) {
    previous.set(name, Object.prototype.hasOwnProperty.call(globalThis, name)
      ? { exists: true, value: globalThis[name] }
      : { exists: false });
    globalThis[name] = value;
  }

  return {
    menus,
    observers,
    restoreGlobals() {
      for (const [name, state] of previous) {
        if (state.exists) globalThis[name] = state.value;
        else delete globalThis[name];
      }
    },
  };
}

test('installs, reports, and restores all six reasoning labels', () => {
  const menu = createMenu();
  const fixture = installFixture([menu]);
  try {
    const result = installInRenderer('fixture-version');
    assert.equal(result.replacements, 6);
    assert.deepEqual(menu.textNodes.map((node) => node.nodeValue), patched);
    const status = statusInRenderer();
    assert.equal(status.installed, true);
    assert.equal(status.version, 'fixture-version');
    assert.equal(status.verification, 'six-labels-verified');
    assert.equal(status.menuMatches, 1);
    assert.equal(status.patchedLabels, 6);
    assert.equal(status.maxPatchedLabels, 6);
    assert.equal(status.replacements, 6);
    assert.equal(typeof status.lastAppliedAt, 'number');
    assert.deepEqual(removeFromRenderer(), { installed: false, removed: true });
    assert.deepEqual(menu.textNodes.map((node) => node.nodeValue), originals);
  } finally {
    globalThis.window?.__codexReasoningLabelHotpatch?.restore?.();
    fixture.restoreGlobals();
  }
});

test('patches a hidden menu when its visibility attributes change', async () => {
  const fixture = installFixture();
  try {
    assert.equal(installInRenderer('fixture-version').replacements, 0);
    assert.equal(statusInRenderer().verification, 'waiting-for-menu');
    const menu = createMenu();
    fixture.menus.push(menu);
    fixture.observers[0].trigger();
    await Promise.resolve();

    assert.deepEqual(menu.textNodes.map((node) => node.nodeValue), patched);
    assert.equal(statusInRenderer().verification, 'six-labels-verified');
    assert.equal(statusInRenderer().maxPatchedLabels, 6);
    assert.equal(fixture.observers[0].options.attributes, true);
    assert.deepEqual(fixture.observers[0].options.attributeFilter, ['data-state', 'aria-hidden', 'inert']);
  } finally {
    globalThis.window?.__codexReasoningLabelHotpatch?.restore?.();
    fixture.restoreGlobals();
  }
});
