const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-chat-'));
process.env.WATCHDOG_DATA_DIR = tmpDir;
process.env.DEEPSEEK_API_KEY = 'test-key';

const app = require('../src/server');
const db = require('../src/db');

let server;
let base;

before(async () => {
  server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => new Promise((r) => server.close(r)));

const H = { 'Content-Type': 'application/json', 'X-Device-Id': 'chat-device', 'X-Actor-Name': 'tester' };
const REPLY = '先确认气瓶余量和空气呼吸器状态';

// 保留原始 fetch：只 mock 发往 LLM 的请求，本服务自身的 HTTP 调用走真实 fetch
const realFetch = globalThis.fetch;

// mock LLM：校验请求形态，固定返回 REPLY
const mockChat = () => {
  globalThis.fetch = (url, opts) => {
    if (!String(url).match(/\/responses$/)) return realFetch(url, opts);
    const body = JSON.parse(opts.body);
    assert.equal(body.model, 'deepseek-v4-flash');
    assert.match(body.instructions, /水元素/);
    assert.deepEqual(body.tools, [{ type: 'web_search' }]);
    return Promise.resolve({
      ok: true,
      async json() {
        return { output_text: REPLY };
      },
    });
  };
};

test('POST /api/chat 缺 message 400', async () => {
  const res = await fetch(`${base}/api/chat`, { method: 'POST', headers: H, body: JSON.stringify({}) });
  assert.equal(res.status, 400);
});

test('POST /api/chat 无警情也可问答且不落云端历史', async () => {
  mockChat();
  const res = await fetch(`${base}/api/chat`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ message: '浓烟太大看不清怎么办' }),
  });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.reply, REPLY);

  const list = await (await fetch(`${base}/api/chat`, { headers: H })).json();
  assert.deepEqual(list, []);
});

test('POST /api/chat 历史上下文带入请求', async () => {
  let captured = null;
  globalThis.fetch = (url, opts) => {
    if (!String(url).match(/\/responses$/)) return realFetch(url, opts);
    captured = JSON.parse(opts.body);
    return Promise.resolve({
      ok: true,
      async json() {
        return { output_text: '收到' };
      },
    });
  };
  await fetch(`${base}/api/chat`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({
      message: '再问一个',
      history: [{ role: 'user', content: '浓烟太大看不清怎么办' }, { role: 'assistant', content: REPLY }],
    }),
  });
  const userMsgs = captured.input.filter((m) => m.role === 'user').map((m) => m.content);
  assert.ok(userMsgs.includes('再问一个'), '新问题应传入');
  assert.ok(userMsgs.includes('浓烟太大看不清怎么办'), '历史问题应带入上下文');
  assert.ok(userMsgs.length >= 2, `历史上下文未完整带入（user 消息 ${userMsgs.length} 条）`);
});

test('POST /api/chat 联网搜索失败回退普通问答', async () => {
  let fellBack = false;
  globalThis.fetch = (url, opts) => {
    if (String(url).match(/\/responses$/)) {
      return Promise.resolve({ ok: false, status: 500, async text() { return 'boom'; } });
    }
    if (String(url).match(/chat\/completions$/)) {
      fellBack = true;
      const body = JSON.parse(opts.body);
      assert.equal(body.model, 'deepseek-chat');
      return Promise.resolve({
        ok: true,
        async json() {
          return { choices: [{ message: { content: '兜底回复' } }] };
        },
      });
    }
    return realFetch(url, opts);
  };
  const res = await fetch(`${base}/api/chat`, { method: 'POST', headers: H, body: JSON.stringify({ message: '兜底测试' }) });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.reply, '兜底回复');
  assert.ok(fellBack, 'Responses 失败后应回退 chat/completions');
});

test('POST /api/chat 流式（stream=1）：SSE 增量输出且不落云端历史', async () => {
  let streamed = false;
  globalThis.fetch = (url, opts) => {
    if (String(url).match(/chat\/completions$/)) {
      const body = JSON.parse(opts.body);
      assert.equal(body.stream, true, '流式应请求 stream: true');
      assert.equal(body.model, 'deepseek-v4-flash');
      streamed = true;
      const enc = new TextEncoder();
      const sse = [
        'data: {"choices":[{"delta":{"content":"先"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"确认"}}]}\n\n',
        'data: [DONE]\n\n',
      ].join('');
      return Promise.resolve({
        ok: true,
        body: new ReadableStream({
          start(c) {
            c.enqueue(enc.encode(sse));
            c.close();
          },
        }),
      });
    }
    return realFetch(url, opts);
  };
  const res = await fetch(`${base}/api/chat`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ message: '流式问题', stream: 1 }),
  });
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /text\/event-stream/);
  const text = await res.text();
  assert.ok(text.includes('"content":"先"'), '应包含第一段增量');
  assert.ok(text.includes('"content":"确认"'), '应包含第二段增量');
  assert.ok(text.includes('[DONE]'), '应以 [DONE] 结束');
  assert.ok(streamed, '应命中 chat/completions 流式端点');

  const list = await (await fetch(`${base}/api/chat`, { headers: H })).json();
  assert.deepEqual(list, []);
});

test('GET /api/chat 无警情也返回空历史', async () => {
  const list = await (await fetch(`${base}/api/chat`, { headers: H })).json();
  assert.deepEqual(list, []);
});

test('DELETE /api/chat 兼容旧客户端但不操作云端记录', async () => {
  const res = await (await fetch(`${base}/api/chat`, { method: 'DELETE', headers: H })).json();
  assert.ok(res.ok);
  assert.equal(res.deleted, 0);
});

test('POST /api/chat 限流：30 次内必然触发 429（按分钟桶）', async () => {
  mockChat();
  let saw429 = false;
  for (let i = 0; i < 30 && !saw429; i++) {
    const res = await fetch(`${base}/api/chat`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ message: `限流问题${i}` }),
    });
    saw429 = res.status === 429;
  }
  assert.ok(saw429, '30 次内应触发限流');
});
