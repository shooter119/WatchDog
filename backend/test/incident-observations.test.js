const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-observations-'));
process.env.WATCHDOG_DATA_DIR = tmpDir;

const app = require('../src/server');
const db = require('../src/db');
const { buildContext } = require('../src/incident-chat-context');

let server;
let base;

before(async () => {
  server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => new Promise((r) => server.close(r)));

const H = {
  'Content-Type': 'application/json',
  'X-Incident-Id': 'obsscene',
  'X-Device-Id': 'obs-device',
  'X-Actor-Name': 'tester',
};

test('现场口述记录：创建 → 列表 → 证据字段完整', async () => {
  db.createIncident({ id: 'obsscene' });

  // 缺内容 400
  let res = await fetch(`${base}/api/incident-observations`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ transcript: '   ' }),
  });
  assert.equal(res.status, 400);
  assert.equal((await res.json()).code, 'TRANSCRIPT_REQUIRED');

  // 正常创建
  const capturedAt = Date.now() - 5 * 60 * 1000;
  res = await fetch(`${base}/api/incident-observations`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({
      transcript: '三楼东侧窗口还有两人被困，正在架梯',
      source_type: 'video',
      captured_at: capturedAt,
      media_ref: 'media_123',
      structured: { trapped: 2, location: '三楼东侧' },
    }),
  });
  assert.equal(res.status, 201);
  const created = await res.json();
  assert.equal(created.incident_id, 'obsscene');
  assert.equal(created.transcript, '三楼东侧窗口还有两人被困，正在架梯');
  assert.equal(created.source_type, 'video');
  assert.equal(Number(created.captured_at), capturedAt);
  assert.equal(created.status, 'confirmed');
  assert.equal(created.media_ref, 'media_123');

  // 列表按拍摄时间倒序
  const listed = await (await fetch(`${base}/api/incident-observations`, { headers: H })).json();
  assert.equal(listed.length, 1);
  assert.equal(listed[0].id, created.id);
  assert.ok(listed[0].transcript.includes('三楼东侧'));
});

test('现场口述记录：超长内容与未来时间被拒绝', async () => {
  const tooLong = await fetch(`${base}/api/incident-observations`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ transcript: '火'.repeat(4001) }),
  });
  assert.equal(tooLong.status, 400);
  assert.equal((await tooLong.json()).code, 'TRANSCRIPT_TOO_LONG');

  const future = await fetch(`${base}/api/incident-observations`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({
      transcript: '未来时间不该被接受',
      captured_at: Date.now() + 10 * 60 * 1000,
    }),
  });
  assert.equal(future.status, 400);
  assert.equal((await future.json()).code, 'CAPTURED_AT_INVALID');
});

test('问答上下文注入口述记录：限 5 条、截断、脱敏、保留原始顺序', () => {
  const observations = Array.from({ length: 8 }, (_, index) => ({
    captured_at: 1000 + index,
    source_type: 'video',
    transcript: `第${index}条 联系电话13812345678 现场情况`,
  }));
  const context = buildContext(
    { id: 'i', title: '测试警情' },
    { version: 1, data: { location: '某住宅' } },
    [],
    observations,
  );
  assert.equal(context.observations.length, 5);
  assert.equal(JSON.stringify(context).includes('13812345678'), false, '手机号必须脱敏');
  assert.ok(context.observations[0].text.startsWith('第0条'));

  const long = buildContext(
    { id: 'i' },
    { version: 1, data: {} },
    [],
    [{ captured_at: 1, source_type: 'video', transcript: '火'.repeat(1000) }],
  );
  assert.equal(long.observations[0].text.length, 300, '单条截断到 300 字');
});

test('无口述记录时上下文不出现空数组噪声', () => {
  const context = buildContext({ id: 'i' }, { version: 1, data: {} }, [], []);
  assert.deepEqual(context.observations, []);
});
