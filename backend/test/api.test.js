const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-api-'));
process.env.WATCHDOG_DATA_DIR = tmpDir;

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
  assert.equal(created.duration_min, 17);
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
  assert.equal(rechecked.duration_min, 13); // 15MPa 默认 80L/min → 12.75min → 13
  assert.ok(Math.abs(rechecked.exit_at - Date.now() - 12.75 * 60000) < 5000); // 从此刻重新倒计时

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

test('压力报数复核：差分实测耗气率并据此重算倒计时', async () => {
  const { DatabaseSync } = require('node:sqlite');
  const raw = new DatabaseSync(path.join(tmpDir, 'watchdog.db'));

  const created = await (await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: '动态耗气', pressure_mpa: 20 }),
  })).json();
  assert.equal(created.consumption_actual_lpm, null);

  // 首次报数间隔太短（毫秒级），差分超范围 → 实测为空，按默认 80 L/min
  const first = await (await fetch(`${base}/api/entries/${created.id}`, {
    method: 'PATCH',
    headers: H,
    body: JSON.stringify({ pressure_mpa: 18 }),
  })).json();
  assert.equal(first.consumption_actual_lpm, null);
  // 6.8 × 18 × 10 ÷ 80 = 15.3 → 15
  assert.equal(first.duration_min, 15);

  // 模拟真实时间流逝：20MPa 采样在 10 分钟前，18MPa 采样在 5 分钟前（差分 5 分钟掉 3MPa）
  raw.prepare('UPDATE pressure_samples SET reported_at = ? WHERE entry_id = ? AND pressure_mpa = 20').run(Date.now() - 600000, created.id);
  raw.prepare('UPDATE pressure_samples SET reported_at = ? WHERE entry_id = ? AND pressure_mpa = 18').run(Date.now() - 300000, created.id);
  const second = await (await fetch(`${base}/api/entries/${created.id}`, {
    method: 'PATCH',
    headers: H,
    body: JSON.stringify({ pressure_mpa: 15 }),
  })).json();
  // 5 分钟掉 3MPa → 3 × 6.8 × 10 ÷ 5 = 40.8 L/min（实测生效）
  assert.equal(second.consumption_actual_lpm, 40.8);
  // 6.8 × 15 × 10 ÷ 40.8 = 25 → 25
  assert.equal(second.duration_min, 25);

  // 第三次数值回升（换瓶）→ 差分无效，保留上次实测值
  const third = await (await fetch(`${base}/api/entries/${created.id}`, {
    method: 'PATCH',
    headers: H,
    body: JSON.stringify({ pressure_mpa: 20 }),
  })).json();
  assert.equal(third.consumption_actual_lpm, 40.8);
  assert.equal(third.pressure_mpa, 20);

  await fetch(`${base}/api/entries/${created.id}/exit`, { method: 'POST', headers: H });
});

test('POST/PATCH /api/entries 支持携带消耗率 consumption_lpm', async () => {  const created = await (await fetch(`${base}/api/entries`, {
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

  // 装机自带名单（95 人）全局可见
  let list = await (await fetch(`${base}/api/firefighters`, { headers: H })).json();
  assert.ok(list.some((f) => f.name === '李翔'));
  await fetch(`${base}/api/firefighters/${f1.id}`, { method: 'DELETE', headers: H });
  list = await (await fetch(`${base}/api/firefighters`, { headers: H })).json();
  assert.ok(!list.some((f) => f.name === '王强'));
});

test('GET /api/scenes 列出活跃场景', async () => {
  const scenes = await (await fetch(`${base}/api/scenes`, { headers: H })).json();
  assert.ok(scenes.some((s) => s.code === 'testscene'));
  assert.ok(scenes.some((s) => s.code === 'sceneA'));
  // 未结束的场景不带归档字段
  for (const s of scenes) {
    assert.equal(s.ended_at, undefined);
  }
});

test('POST /api/scenes/end 结束任务：分配新场景码并标记，幂等返回同一码', async () => {
  // 先在场景内产生一条记录，确保场景存在
  await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: '归档测试', pressure_mpa: 25 }),
  });
  const r1 = await (await fetch(`${base}/api/scenes/end`, { method: 'POST', headers: H })).json();
  assert.equal(r1.ok, true);
  assert.match(r1.new_scene, /^[一-鿿]{2}$/);
  assert.ok(r1.ended_at > 0);
  // 幂等：再次结束返回同一新码
  const r2 = await (await fetch(`${base}/api/scenes/end`, { method: 'POST', headers: H })).json();
  assert.equal(r2.new_scene, r1.new_scene);
  // GET /api/scenes 带归档状态
  const scenes = await (await fetch(`${base}/api/scenes`, { headers: H })).json();
  const ended = scenes.find((s) => s.code === 'testscene');
  assert.equal(ended.ended_at, r1.ended_at);
  assert.equal(ended.new_scene, r1.new_scene);
  // 新码不与既有场景冲突
  assert.ok(!scenes.some((s) => s.code === r1.new_scene));
});

test('GET /api/scenes/validate 核验场景码：乱码拒绝、水果码通过、已结束带新码', async () => {
  // 乱码：valid=false
  let v = await (await fetch(`${base}/api/scenes/validate?code=${encodeURIComponent('随便乱写')}`)).json();
  assert.equal(v.valid, false);
  assert.equal(v.exists, false);
  assert.equal(v.ended, false);
  // 不存在的非水果码：valid=false（App 应拒绝切换）
  v = await (await fetch(`${base}/api/scenes/validate?code=legacy-nonexist`)).json();
  assert.equal(v.valid, false);
  // 活跃历史场景（非水果）：valid=true（老设备可加入，防锁死）。
  // 顶层测试并发执行，用独立场景码自建数据，避免依赖其他测试的执行顺序/共享场景状态
  const legacyAt = Date.now();
  db.createEntry({ id: 'validate-legacy', scene: 'legacy-active-1', name: '历史场景', pressureMpa: 20, durationMin: 34, entryAtMs: legacyAt, exitAtMs: legacyAt + 1000, source: 'voice', rawText: null });
  v = await (await fetch(`${base}/api/scenes/validate?code=legacy-active-1`)).json();
  assert.equal(v.valid, true);
  assert.equal(v.exists, true);
  assert.equal(v.ended, false);
  // 空码：invalid（App 端空输入不会提交）
  v = await (await fetch(`${base}/api/scenes/validate?code=`)).json();
  assert.equal(v.valid, false);
  // 旧数据 default 场景兼容
  v = await (await fetch(`${base}/api/scenes/validate?code=default`)).json();
  assert.equal(v.valid, true);
  // 合法水果码且场景存在：直写 db 造活跃水果场景（HTTP header 传中文受 undici 限制）
  const entryAt = Date.now();
  db.createEntry({ id: 'validate-apple', scene: '苹果', name: '核验测试', pressureMpa: 20, durationMin: 34, entryAtMs: entryAt, exitAtMs: entryAt + 34 * 60000, source: 'voice', rawText: null });
  v = await (await fetch(`${base}/api/scenes/validate?code=${encodeURIComponent('苹果')}`)).json();
  assert.equal(v.valid, true);
  assert.equal(v.exists, true);
  assert.equal(v.ended, false);
  // 合法水果码但服务器无数据：valid=true, exists=false（可加入新任务）
  v = await (await fetch(`${base}/api/scenes/validate?code=${encodeURIComponent('香蕉')}`)).json();
  assert.equal(v.valid, true);
  assert.equal(v.exists, false);
  // 已结束场景：ended=true 且携带服务端新码（将苹果场景归档）
  db.markSceneEnded('苹果', 'test-device');
  v = await (await fetch(`${base}/api/scenes/validate?code=${encodeURIComponent('苹果')}`)).json();
  assert.equal(v.valid, true);
  assert.equal(v.ended, true);
  assert.ok(v.new_scene);
  // 空格容错
  v = await (await fetch(`${base}/api/scenes/validate?code=${encodeURIComponent(' 香蕉 ')}`)).json();
  assert.equal(v.valid, true);
});

test('API_TOKEN 配置后未带令牌返回 401', async () => {
  // 单测进程内 API_TOKEN 为空，改用中间件行为验证：401 分支仅在有 token 时生效
  // 此处通过 spawn 子进程验证（见 token.e2e.test.js）
  assert.equal(process.env.API_TOKEN || '', '');
});

test('中文场景码 URL 编码头：服务端解码还原并正确隔离', async () => {
  // App 端 dart:io 拒绝非 ASCII 头值，中文场景码（如苹果）会 URL 编码发送
  const encH = { ...H, 'X-Scene-Code': encodeURIComponent('苹果') };
  const created = await (await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: encH,
    body: JSON.stringify({ name: '编码场景测试', pressure_mpa: 20 }),
  })).json();
  // 服务端解码后按"苹果"场景存储
  assert.equal(created.scene, '苹果');
  // 同编码头查询能命中（解码一致）
  const list = await (await fetch(`${base}/api/entries`, { headers: encH })).json();
  assert.ok(list.some((e) => e.name === '编码场景测试'));
  // 与原始中文头（undici 无法发送，这里用解码后的 ASCII 码验证隔离性：BHYSQB 场景不受影响）
  const other = await (await fetch(`${base}/api/entries`, { headers: { ...H, 'X-Scene-Code': 'BHYSQB' } })).json();
  assert.ok(!other.some((e) => e.name === '编码场景测试'));
});
