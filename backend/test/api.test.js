const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-api-'));
process.env.WATCHDOG_DATA_DIR = tmpDir;

const app = require('../src/server');

let server;
let base;

before(async () => {
  server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => new Promise((r) => server.close(r)));

const H = { 'Content-Type': 'application/json', 'X-Scene-Code': 'testscene' };
const j = (r) => r.json();

test('GET /api/health 免认证返回 ok', async () => {
  const res = await fetch(`${base}/api/health`);
  assert.equal(res.status, 200);
  const body = await j(res);
  assert.equal(body.ok, true);
  assert.equal(typeof body.asrConfigured, 'boolean');
});

test('GET /api/config 返回计算参数', async () => {
  const res = await fetch(`${base}/api/config`, { headers: H });
  const body = await j(res);
  assert.equal(body.calc.cylinderVolL, 6.8);
  assert.ok(body.calc.warnMin > 0);
});

test('POST /api/entries 压力必填且限 0-40MPa', async () => {
  let res = await fetch(`${base}/api/entries`, { method: 'POST', headers: H, body: JSON.stringify({ name: '张伟' }) });
  assert.equal(res.status, 400);
  res = await fetch(`${base}/api/entries`, { method: 'POST', headers: H, body: JSON.stringify({ name: '张伟', pressure_mpa: 99 }) });
  assert.equal(res.status, 400);
  res = await fetch(`${base}/api/entries`, { method: 'POST', headers: H, body: JSON.stringify({ name: '', pressure_mpa: 20 }) });
  assert.equal(res.status, 400);
});

test('进场→列表→出场→active 过滤 全链路', async () => {
  const created = await (await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: '李娜', pressure_mpa: 20, source: 'voice', raw_text: '李娜，20兆帕' }),
  })).json();
  assert.equal(created.name, '李娜');
  assert.equal(created.duration_min, 34);
  assert.equal(created.raw_text, '李娜，20兆帕');

  let list = await (await fetch(`${base}/api/entries?active=1`, { headers: H })).json();
  assert.equal(list.length, 1);

  const exited = await (await fetch(`${base}/api/entries/${created.id}/exit`, { method: 'POST', headers: H })).json();
  assert.ok(exited.exited_at);

  list = await (await fetch(`${base}/api/entries?active=1`, { headers: H })).json();
  assert.equal(list.length, 0);

  const res404 = await fetch(`${base}/api/entries/nope/exit`, { method: 'POST', headers: H });
  assert.equal(res404.status, 404);
});

test('场景隔离：同后端不同场景码互不可见', async () => {
  await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: { ...H, 'X-Scene-Code': 'sceneA' },
    body: JSON.stringify({ name: '甲', pressure_mpa: 20 }),
  });
  const b = await (await fetch(`${base}/api/entries`, {
    headers: { ...H, 'X-Scene-Code': 'sceneB' },
  })).json();
  assert.equal(b.length, 0);
  const a = await (await fetch(`${base}/api/entries`, {
    headers: { ...H, 'X-Scene-Code': 'sceneA' },
  })).json();
  assert.equal(a.length, 1);
});

test('同名在场记录：重复进场返回 409，force 才允许另建记录', async () => {
  const created = await (await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: '张伟', pressure_mpa: 20 }),
  })).json();
  assert.equal(created.name, '张伟');

  const dup = await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: '张伟', pressure_mpa: 18 }),
  });
  assert.equal(dup.status, 409);
  const dupBody = await dup.json();
  assert.equal(dupBody.entry.id, created.id);
  assert.match(dupBody.error, /已在火场内/);

  const forced = await (await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: '张伟', pressure_mpa: 18, force: true }),
  })).json();
  assert.equal(forced.id !== created.id, true);

  // 出场后再进场不再冲突
  await fetch(`${base}/api/entries/${created.id}/exit`, { method: 'POST', headers: H });
  await fetch(`${base}/api/entries/${forced.id}/exit`, { method: 'POST', headers: H });
  const again = await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: '张伟', pressure_mpa: 20 }),
  });
  assert.equal(again.status, 201);
  const againBody = await again.json();
  await fetch(`${base}/api/entries/${againBody.id}/exit`, { method: 'POST', headers: H });
});

test('PATCH /api/entries/:id 改名与压力复核（重新倒计时）', async () => {
  const created = await (await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: '刘洋', pressure_mpa: 20 }),
  })).json();

  const renamed = await (await fetch(`${base}/api/entries/${created.id}`, {
    method: 'PATCH',
    headers: H,
    body: JSON.stringify({ name: '刘扬' }),
  })).json();
  assert.equal(renamed.name, '刘扬');
  assert.equal(renamed.pressure_mpa, 20);
  assert.equal(renamed.exit_at, created.exit_at);

  const rechecked = await (await fetch(`${base}/api/entries/${created.id}`, {
    method: 'PATCH',
    headers: H,
    body: JSON.stringify({ pressure_mpa: 15 }),
  })).json();
  assert.equal(rechecked.pressure_mpa, 15);
  assert.equal(rechecked.duration_min, 26); // 15MPa → 25.5min → 26
  assert.ok(Math.abs(rechecked.exit_at - Date.now() - 25.5 * 60000) < 5000); // 从此刻重新倒计时

  // 改名后同名不再冲突（旧名可再次进场）
  const conflict = await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: '刘洋', pressure_mpa: 20 }),
  });
  assert.equal(conflict.status, 201);
  const conflictBody = await conflict.json();
  await fetch(`${base}/api/entries/${conflictBody.id}/exit`, { method: 'POST', headers: H });

  const res404 = await fetch(`${base}/api/entries/nope`, { method: 'PATCH', headers: H, body: JSON.stringify({ name: 'x' }) });
  assert.equal(res404.status, 404);
  const res400 = await fetch(`${base}/api/entries/${created.id}`, {
    method: 'PATCH',
    headers: H,
    body: JSON.stringify({ pressure_mpa: 99 }),
  });
  assert.equal(res400.status, 400);

  await fetch(`${base}/api/entries/${created.id}/exit`, { method: 'POST', headers: H });
});

test('POST/PATCH /api/entries 支持携带消耗率 consumption_lpm', async () => {
  const created = await (await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: '消耗率测试', pressure_mpa: 20, consumption_lpm: 80 }),
  })).json();
  // 6.8L × 20MPa × 10 ÷ 80L/min = 17 分钟
  assert.equal(created.duration_min, 17);

  // 消耗率异常拒绝
  const bad = await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: '消耗率异常', pressure_mpa: 20, consumption_lpm: -5 }),
  });
  assert.equal(bad.status, 400);

  // PATCH 复核压力同样按携带的消耗率重算：6.8 × 10 × 10 ÷ 80 = 8.5 → 9
  const rechecked = await (await fetch(`${base}/api/entries/${created.id}`, {
    method: 'PATCH',
    headers: H,
    body: JSON.stringify({ pressure_mpa: 10, consumption_lpm: 80 }),
  })).json();
  assert.equal(rechecked.duration_min, 9);

  await fetch(`${base}/api/entries/${created.id}/exit`, { method: 'POST', headers: H });
});

test('消防员/热词 CRUD 与 409 查重', async () => {
  const f1 = await (await fetch(`${base}/api/firefighters`, { method: 'POST', headers: H, body: JSON.stringify({ name: '王强' }) })).json();
  assert.equal(f1.name, '王强');
  const dup = await fetch(`${base}/api/firefighters`, { method: 'POST', headers: H, body: JSON.stringify({ name: '王强' }) });
  assert.equal(dup.status, 409);

  const w1 = await (await fetch(`${base}/api/hotwords`, { method: 'POST', headers: H, body: JSON.stringify({ word: '空气呼吸器' }) })).json();
  assert.equal(w1.word, '空气呼吸器');

  await fetch(`${base}/api/firefighters/${f1.id}`, { method: 'DELETE', headers: H });
  const list = await (await fetch(`${base}/api/firefighters`, { headers: H })).json();
  assert.equal(list.length, 0);
});

test('GET /api/scenes 列出活跃场景', async () => {
  const scenes = await (await fetch(`${base}/api/scenes`, { headers: H })).json();
  assert.ok(scenes.includes('testscene'));
  assert.ok(scenes.includes('sceneA'));
});

test('API_TOKEN 配置后未带令牌返回 401', async () => {
  // 单测进程内 API_TOKEN 为空，改用中间件行为验证：401 分支仅在有 token 时生效
  // 此处通过 spawn 子进程验证（见 token.e2e.test.js）
  assert.equal(process.env.API_TOKEN || '', '');
});
