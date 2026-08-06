const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-notes-'));
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

const H = { 'Content-Type': 'application/json', 'X-Scene-Code': 'notescene' };
const j = (r) => r.json();

test('火场随手记 CRUD 全链路：创建→列表→编辑→删除', async () => {
  // 缺内容 400
  let res = await fetch(`${base}/api/notes`, { method: 'POST', headers: H, body: JSON.stringify({ text: '   ' }) });
  assert.equal(res.status, 400);

  // 创建
  const created = await (await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ text: '水带铺设完成，北侧出水', category: '出水' }),
  })).json();
  assert.equal(created.text, '水带铺设完成，北侧出水');
  assert.equal(created.category, '出水');
  assert.ok(created.created_at > 0);
  assert.equal(created.updated_at, created.created_at);

  // 重命名后的"部署"分类在白名单内
  const deployCat = await (await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ text: '支队全勤指挥部到达现场', category: '部署' }),
  })).json();
  assert.equal(deployCat.category, '部署');

  // 非法分类回落为"其他"
  const badCat = await (await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ text: '二楼发现被困人员', category: '乱写' }),
  })).json();
  assert.equal(badCat.category, '其他');

  // 列表新→旧
  const list = await (await fetch(`${base}/api/notes`, { headers: H })).json();
  assert.equal(list.length, 3);
  assert.ok(list.some((n) => n.id === deployCat.id && n.category === '部署'));

  // 编辑文本与分类
  const updated = await (await fetch(`${base}/api/notes/${created.id}`, {
    method: 'PATCH',
    headers: H,
    body: JSON.stringify({ text: '北侧出水正常，压力充足', category: '搜救' }),
  })).json();
  assert.equal(updated.text, '北侧出水正常，压力充足');
  assert.equal(updated.category, '搜救');
  assert.ok(updated.updated_at >= updated.created_at);

  // 空文本 400、不存在 404
  res = await fetch(`${base}/api/notes/${created.id}`, { method: 'PATCH', headers: H, body: JSON.stringify({ text: '' }) });
  assert.equal(res.status, 400);
  res = await fetch(`${base}/api/notes/nope`, { method: 'PATCH', headers: H, body: JSON.stringify({ text: 'x' }) });
  assert.equal(res.status, 404);

  // 删除
  res = await fetch(`${base}/api/notes/${created.id}`, { method: 'DELETE', headers: H });
  assert.equal(res.status, 200);
  res = await fetch(`${base}/api/notes/${created.id}`, { method: 'DELETE', headers: H });
  assert.equal(res.status, 404);
  const afterDel = await (await fetch(`${base}/api/notes`, { headers: H })).json();
  assert.equal(afterDel.length, 2);
});

test('场景隔离：不同场景码的随手记互不可见', async () => {
  const resA = await (await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: { ...H, 'X-Scene-Code': 'noteA' },
    body: JSON.stringify({ text: 'A 场景记录' }),
  })).json();
  assert.ok(resA.id);

  const b = await (await fetch(`${base}/api/notes`, { headers: { ...H, 'X-Scene-Code': 'noteB' } })).json();
  assert.equal(b.length, 0);
  const a = await (await fetch(`${base}/api/notes`, { headers: { ...H, 'X-Scene-Code': 'noteA' } })).json();
  assert.equal(a.length, 1);
  assert.equal(a[0].text, 'A 场景记录');
});
