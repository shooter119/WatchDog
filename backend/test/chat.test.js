const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-chat-'));
process.env.WATCHDOG_DATA_DIR = tmpDir;
process.env.DEEPSEEK_API_KEY = 'test-key';

const app = require('../src/server');

let server;
let base;

before(async () => {
  server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => new Promise((r) => server.close(r)));

const H = { 'Content-Type': 'application/json', 'X-Scene-Code': 'chatscene' };
const REPLY = '先确认气瓶余量和空气呼吸器状态';

// 保留原始 fetch：只 mock 发往 LLM 的请求，本服务自身的 HTTP 调用走真实 fetch
const realFetch = globalThis.fetch;

// mock LLM：校验请求形态，固定返回 REPLY
const mockChat = () => {
  globalThis.fetch = (url, opts) => {
    if (!String(url).match(/chat\/completions$/)) return realFetch(url, opts);
    const body = JSON.parse(opts.body);
    assert.equal(body.model, 'deepseek-chat');
    assert.equal(body.messages[0].role, 'system');
    assert.match(body.messages[0].content, /辅助/);
    return Promise.resolve({
      ok: true,
      async json() {
        return { choices: [{ message: { content: REPLY } }] };
      },
    });
  };
};

test('POST /api/chat 缺 message 400', async () => {
  const res = await fetch(`${base}/api/chat`, { method: 'POST', headers: H, body: JSON.stringify({}) });
  assert.equal(res.status, 400);
});

test('POST /api/chat 问答全链路：回复落库成对写入', async () => {
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
  assert.equal(list.length, 2);
  assert.equal(list[0].role, 'user');
  assert.equal(list[0].content, '浓烟太大看不清怎么办');
  assert.equal(list[1].role, 'assistant');
  assert.equal(list[1].content, REPLY);
});

test('POST /api/chat 历史上下文带入请求', async () => {
  let captured = null;
  globalThis.fetch = (url, opts) => {
    if (!String(url).match(/chat\/completions$/)) return realFetch(url, opts);
    captured = JSON.parse(opts.body);
    return Promise.resolve({
      ok: true,
      async json() {
        return { choices: [{ message: { content: '收到' } }] };
      },
    });
  };
  await fetch(`${base}/api/chat`, { method: 'POST', headers: H, body: JSON.stringify({ message: '再问一个' }) });
  const userMsgs = captured.messages.filter((m) => m.role === 'user').map((m) => m.content);
  assert.ok(userMsgs.includes('再问一个'), '新问题应传入');
  assert.ok(userMsgs.includes('浓烟太大看不清怎么办'), '历史问题应带入上下文');
  assert.ok(userMsgs.length >= 2, `历史上下文未完整带入（user 消息 ${userMsgs.length} 条）`);
});

test('GET /api/chat 场景隔离', async () => {
  const other = await (
    await fetch(`${base}/api/chat`, { headers: { ...H, 'X-Scene-Code': 'other-scene' } })
  ).json();
  assert.equal(other.length, 0);
});

test('DELETE /api/chat 清空记录', async () => {
  const res = await (await fetch(`${base}/api/chat`, { method: 'DELETE', headers: H })).json();
  assert.ok(res.ok);
  const list = await (await fetch(`${base}/api/chat`, { headers: H })).json();
  assert.equal(list.length, 0);
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
