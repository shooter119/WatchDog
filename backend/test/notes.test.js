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

test('实名用户发布日志携带 author，未实名为空串（匿名）', async () => {
  // 未设置实名（无 X-Device-Id）：author 空串 = 匿名
  const anon = await (await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ text: '匿名发布测试' }),
  })).json();
  assert.equal(anon.author, '');

  // 设备设置实名后发布：author 为真实姓名
  const deviceH = { ...H, 'X-Device-Id': 'notes-device-1' };
  await fetch(`${base}/api/user-settings`, {
    method: 'PUT',
    headers: deviceH,
    body: JSON.stringify({ settings: { real_name: '李娜' } }),
  });
  const named = await (await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: deviceH,
    body: JSON.stringify({ text: '实名发布测试' }),
  })).json();
  assert.equal(named.author, '李娜');

  // 列表同样携带 author
  const list = await (await fetch(`${base}/api/notes`, { headers: H })).json();
  const item = list.find((n) => n.text === '实名发布测试');
  assert.equal(item.author, '李娜');
});

test('日志作者：请求体 author 优先，其次按设备实名，缺省匿名', async () => {
  // 请求体 author 直接生效（不依赖 user_settings）
  const direct = await (await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ text: '直传作者测试', author: '王五' }),
  })).json();
  assert.equal(direct.author, '王五');
  // 无 author 且无设备实名 → 匿名
  const anon = await (await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ text: '无作者测试' }),
  })).json();
  assert.equal(anon.author, '');
  // body author 带空格/超长 → trim + 截断
  const trimmed = await (await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ text: 'trim测试', author: '  赵六  ' }),
  })).json();
  assert.equal(trimmed.author, '赵六');
  // body author 优先于设备实名（设备实名已在其他测试设置过）
  const deviceNamed = await (await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: { ...H, 'X-Device-Id': 'notes-device-1' },
    body: JSON.stringify({ text: '优先级测试', author: '优先作者' }),
  })).json();
  assert.equal(deviceNamed.author, '优先作者');
});
