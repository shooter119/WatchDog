const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-sse-disconnect-'));
process.env.NODE_ENV = 'test';
process.env.WATCHDOG_DATA_DIR = tmpDir;
process.env.DEEPSEEK_API_KEY = 'test-key';
process.env.API_TOKEN = '';

const app = require('../src/server');

let server;
let base;
const realFetch = globalThis.fetch;
const headers = {
  'content-type': 'application/json',
  'x-device-id': 'sse-test-device',
  'x-actor-name': 'tester',
};

before(async () => {
  server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  globalThis.fetch = realFetch;
  await new Promise((resolve) => server.close(resolve));
});

function waitFor(promise, timeoutMs = 1500) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('等待上游取消超时')), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

test('SSE 客户端断开会立即 abort 上游 DeepSeek 请求', async () => {
  let upstreamSignal;
  let resolveAborted;
  const upstreamAborted = new Promise((resolve) => {
    resolveAborted = resolve;
  });

  globalThis.fetch = (url, options) => {
    if (!String(url).endsWith('/chat/completions')) return realFetch(url, options);
    upstreamSignal = options.signal;
    const encoder = new TextEncoder();
    return Promise.resolve({
      ok: true,
      status: 200,
      body: new ReadableStream({
        start(controller) {
          controller.enqueue(encoder.encode('data: {"choices":[{"delta":{"content":"第一段"}}]}\n\n'));
          const onAbort = () => {
            resolveAborted();
            controller.error(new Error('upstream aborted'));
          };
          if (options.signal.aborted) onAbort();
          else options.signal.addEventListener('abort', onAbort, { once: true });
        },
      }),
    });
  };

  const response = await realFetch(`${base}/api/chat`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ message: '请持续输出现场安全建议', stream: 1 }),
  });
  assert.equal(response.status, 200);
  const reader = response.body.getReader();
  const first = await reader.read();
  assert.match(new TextDecoder().decode(first.value), /第一段/);

  await reader.cancel();
  await waitFor(upstreamAborted);
  assert.ok(upstreamSignal instanceof AbortSignal);
  assert.equal(upstreamSignal.aborted, true);
});

test('SSE 上游错误只返回通用错误，不回显上游响应正文', async () => {
  const leaked = 'upstream-secret-diagnostic';
  globalThis.fetch = (url, options) => {
    if (!String(url).endsWith('/chat/completions')) return realFetch(url, options);
    return Promise.resolve({
      ok: false,
      status: 502,
      async text() {
        return leaked;
      },
    });
  };

  const response = await realFetch(`${base}/api/chat`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ message: '请给出现场安全建议', stream: 1 }),
  });
  assert.equal(response.status, 200);
  const body = await response.text();
  assert.match(body, /流式问答失败，请重试/);
  assert.match(body, /\[DONE\]/);
  assert.doesNotMatch(body, new RegExp(leaked));
});
