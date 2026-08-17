import assert from 'node:assert/strict';
import test from 'node:test';

import { createCodexDevToolsTransport } from './codex-devtools-transport.mjs';

const eligibleTarget = {
  id: 'eligible',
  type: 'page',
  url: 'app://-/index.html',
  webSocketDebuggerUrl: 'ws://eligible',
};

function fakeWebSocket(respond) {
  return class FakeWebSocket {
    constructor(url) {
      this.url = url;
      this.listeners = new Map();
      queueMicrotask(() => this.emit('open', {}));
    }

    addEventListener(type, callback) {
      const listeners = this.listeners.get(type) || [];
      listeners.push(callback);
      this.listeners.set(type, listeners);
    }

    send(payload) {
      respond(this, JSON.parse(payload));
    }

    close() {
      this.closed = true;
    }

    emit(type, event) {
      for (const listener of this.listeners.get(type) || []) listener(event);
    }
  };
}

const noTimeoutSignal = () => undefined;

test('falls back across loopback hosts and filters targets once', async () => {
  const requestedUrls = [];
  const fetchImpl = async (url) => {
    requestedUrls.push(url);
    if (!url.includes('[::1]')) throw new Error('unreachable');
    return {
      ok: true,
      async json() {
        return [eligibleTarget, { ...eligibleTarget, id: 'excluded', type: 'other' }];
      },
    };
  };
  const transport = createCodexDevToolsTransport(
    { port: 39252, targetFilter: (target) => target.type === 'page' },
    {
      fetchImpl,
      WebSocketImpl: fakeWebSocket(() => {}),
      hosts: ['localhost', '127.0.0.1', '[::1]'],
      timeoutSignal: noTimeoutSignal,
    },
  );

  assert.deepEqual(await transport.getTargets(), [eligibleTarget]);
  assert.deepEqual(requestedUrls, [
    'http://localhost:39252/json/list',
    'http://127.0.0.1:39252/json/list',
    'http://[::1]:39252/json/list',
  ]);
});
test('reports every failed discovery host', async () => {
  const transport = createCodexDevToolsTransport(
    { port: 1, targetFilter: () => true },
    {
      fetchImpl: async () => { throw new Error('offline'); },
      WebSocketImpl: fakeWebSocket(() => {}),
      hosts: ['a', 'b'],
      timeoutSignal: noTimeoutSignal,
    },
  );

  await assert.rejects(transport.getTargets(), /a: offline; b: offline/);
});

test('evaluates through CDP and returns the renderer value', async () => {
  const WebSocketImpl = fakeWebSocket((socket, message) => {
    queueMicrotask(() => socket.emit('message', {
      data: JSON.stringify({ id: message.id, result: { result: { value: 'renderer-value' } } }),
    }));
  });
  const transport = createCodexDevToolsTransport(
    { port: 1, targetFilter: () => true },
    { fetchImpl: async () => {}, WebSocketImpl, timeoutSignal: noTimeoutSignal },
  );

  assert.equal(await transport.evaluate(eligibleTarget, '1 + 1'), 'renderer-value');
});

test('turns a socket failure into a renderer-specific error', async () => {
  const WebSocketImpl = fakeWebSocket((socket) => {
    queueMicrotask(() => socket.emit('error', {}));
  });
  const transport = createCodexDevToolsTransport(
    { port: 1, targetFilter: () => true },
    { fetchImpl: async () => {}, WebSocketImpl, timeoutSignal: noTimeoutSignal },
  );

  await assert.rejects(transport.evaluate(eligibleTarget, '1'), /renderer eligible/);
});

test('collects per-target errors without losing successful results', async () => {
  const WebSocketImpl = fakeWebSocket((socket, message) => {
    const response = socket.url.includes('failed')
      ? { id: message.id, error: { message: 'renderer rejected command' } }
      : { id: message.id, result: { result: { value: socket.url } } };
    queueMicrotask(() => socket.emit('message', { data: JSON.stringify(response) }));
  });
  const transport = createCodexDevToolsTransport(
    { port: 1, targetFilter: () => true },
    { fetchImpl: async () => {}, WebSocketImpl, timeoutSignal: noTimeoutSignal },
  );
  const failedTarget = { ...eligibleTarget, id: 'failed', webSocketDebuggerUrl: 'ws://failed' };

  assert.deepEqual(await transport.runForTargets('1', [eligibleTarget, failedTarget]), [
    { id: 'eligible', url: 'app://-/index.html', result: 'ws://eligible' },
    { id: 'failed', url: 'app://-/index.html', error: 'renderer rejected command' },
  ]);
});
