const DEFAULT_HOSTS = ['localhost', '127.0.0.1', '[::1]'];

export function createCodexDevToolsTransport(
  {
    port,
    targetFilter,
    commandTimeoutMs = 5000,
    discoveryTimeoutMs = 1500,
  },
  {
    fetchImpl = globalThis.fetch,
    WebSocketImpl = globalThis.WebSocket,
    hosts = DEFAULT_HOSTS,
    timeoutSignal = (timeoutMs) => AbortSignal.timeout(timeoutMs),
  } = {},
) {
  if (!Number.isInteger(port)) throw new TypeError('DevTools port must be an integer.');
  if (typeof targetFilter !== 'function') throw new TypeError('targetFilter must be a function.');
  if (typeof fetchImpl !== 'function') throw new TypeError('fetch implementation is unavailable.');
  if (typeof WebSocketImpl !== 'function') throw new TypeError('WebSocket implementation is unavailable.');

  async function getTargets() {
    const errors = [];
    for (const host of hosts) {
      try {
        const response = await fetchImpl(`http://${host}:${port}/json/list`, {
          signal: timeoutSignal(discoveryTimeoutMs),
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return (await response.json()).filter(targetFilter);
      } catch (error) {
        errors.push(`${host}: ${error.message}`);
      }
    }
    throw new Error(`DevTools endpoint unavailable (${errors.join('; ')}).`);
  }

  function sendCommand(target, method, params = {}) {
    return new Promise((resolve, reject) => {
      const socket = new WebSocketImpl(target.webSocketDebuggerUrl);
      const timeout = setTimeout(() => {
        socket.close();
        reject(new Error(`CDP evaluation timed out for ${target.id}.`));
      }, commandTimeoutMs);

      socket.addEventListener('open', () => {
        socket.send(JSON.stringify({ id: 1, method, params }));
      });
      socket.addEventListener('message', (event) => {
        const message = JSON.parse(event.data);
        if (message.id !== 1) return;
        clearTimeout(timeout);
        socket.close();
        if (message.error || message.result?.exceptionDetails) {
          reject(new Error(message.error?.message || message.result.exceptionDetails.text || 'CDP evaluation failed.'));
        } else {
          resolve(message.result);
        }
      });
      socket.addEventListener('error', () => {
        clearTimeout(timeout);
        socket.close();
        reject(new Error(`Unable to connect to renderer ${target.id}.`));
      });
    });
  }

  function evaluate(target, expression) {
    return sendCommand(target, 'Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    }).then((result) => result?.result?.value);
  }

  async function runForTargets(expression, targets = null) {
    const selectedTargets = targets || await getTargets();
    const results = [];
    for (const target of selectedTargets) {
      try {
        results.push({ id: target.id, url: target.url, result: await evaluate(target, expression) });
      } catch (error) {
        results.push({ id: target.id, url: target.url, error: error.message });
      }
    }
    return results;
  }

  return Object.freeze({ getTargets, evaluate, runForTargets });
}
