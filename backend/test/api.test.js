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

const H = {
  'Content-Type': 'application/json',
  'X-Incident-Id': 'testscene',
  'X-Device-Id': 'api-device',
  'X-Actor-Name': 'tester',
  'X-Unit-Id': 'longyou-county-fire-rescue',
  'X-Unit-Code': '0570',
};
const j = (r) => r.json();

for (const id of ['testscene', 'sceneA', 'sceneB', 'legacy-active-1', '苹果', 'BHYSQB', 'default']) {
  db.createIncident({ id });
}

test('GET /api/health 免认证返回 ok', async () => {
  const res = await fetch(`${base}/api/health`);
  assert.equal(res.status, 200);
  const body = await j(res);
  assert.equal(body.ok, true);
  assert.equal(typeof body.ready, 'boolean');
  assert.equal(typeof body.databaseReady, 'boolean');
  assert.equal(typeof body.asrConfigured, 'boolean');
});

test('GET /api/config 返回计算参数', async () => {
  const res = await fetch(`${base}/api/config`, { headers: H });
  const body = await j(res);
  assert.equal(body.calc.cylinderVolL, 6.8);
  assert.ok(body.calc.warnMin > 0);
  assert.equal(body.unit, null);
});

test('POST /api/auth/verify 校验单位验证码并登记实名', async () => {
  let res = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Device-Id': 'auth-device' },
    body: JSON.stringify({ unit_name: '龙游县消防救援大队', unit_code: '0000', real_name: '李娜' }),
  });
  assert.equal(res.status, 403);
  assert.equal((await res.json()).code, 'UNIT_INVALID');

  res = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Device-Id': 'auth-device' },
    body: JSON.stringify({ unit_name: '龙游县消防救援大队。', unit_code: '0570', real_name: '李娜' }),
  });
  assert.equal(res.status, 403);
  assert.equal((await res.json()).code, 'UNIT_INVALID');

  res = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Device-Id': 'auth-device' },
    body: JSON.stringify({ unit_name: ' 龙游县消防救援大队 ', unit_code: '0570', real_name: ' 李娜 ' }),
  });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.authenticated, true);
  assert.deepEqual(body.unit, { id: 'longyou-county-fire-rescue', name: '龙游县消防救援大队' });
  assert.equal(body.user.real_name, '李娜');
  assert.equal(db.getDeviceProfile('auth-device').real_name, '李娜');
});

test('POST /api/auth/verify 拒绝超长单位验证码', async () => {
  const res = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Device-Id': 'auth-length-device' },
    body: JSON.stringify({ unit_name: '龙游县消防救援大队', unit_code: 'x'.repeat(65), real_name: '李娜' }),
  });
  assert.equal(res.status, 400);
  assert.equal((await res.json()).code, 'UNIT_CODE_INVALID');
});

test('带幂等语义的请求拒绝超长操作 ID，不静默截断', async () => {
  const res = await fetch(`${base}/api/incidents`, {
    method: 'POST',
    headers: { ...H, 'X-Op-Id': 'x'.repeat(65) },
    body: JSON.stringify({ actor_name: '测试员' }),
  });
  assert.equal(res.status, 400);
  assert.equal((await res.json()).code, 'OP_ID_TOO_LONG');
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

test('警情隔离：同后端不同警情互不可见', async () => {
  await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: { ...H, 'X-Incident-Id': 'sceneA' },
    body: JSON.stringify({ name: '甲', pressure_mpa: 20 }),
  });
  const b = await (await fetch(`${base}/api/entries`, {
    headers: { ...H, 'X-Incident-Id': 'sceneB' },
  })).json();
  assert.equal(b.length, 0);
  const a = await (await fetch(`${base}/api/entries`, {
    headers: { ...H, 'X-Incident-Id': 'sceneA' },
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

test('PATCH /api/entries/:id 拒绝超长姓名', async () => {
  const created = await (await fetch(`${base}/api/entries`, {
    method: 'POST', headers: H, body: JSON.stringify({ name: '边界人员', pressure_mpa: 20 }),
  })).json();
  const res = await fetch(`${base}/api/entries/${created.id}`, {
    method: 'PATCH', headers: H, body: JSON.stringify({ name: 'x'.repeat(65) }),
  });
  assert.equal(res.status, 400);
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

test('GET /api/incidents 列出活跃警情并返回汇总字段', async () => {
  const incidents = await (await fetch(`${base}/api/incidents?status=active`, { headers: H })).json();
  const current = incidents.find((item) => item.id === 'testscene');
  assert.ok(current);
  assert.equal(current.status, 'active');
  assert.ok('display_name' in current);
  assert.ok(Array.isArray(current.forces));
});

test('POST /api/incidents/archive 归档并幂等返回同一档案', async () => {
  const created = await (await fetch(`${base}/api/incidents`, {
    method: 'POST',
    headers: { ...H, 'X-Op-Id': 'api-create-archive' },
    body: JSON.stringify({ actor_name: '测试员' }),
  })).json();
  const incidentHeaders = { ...H, 'X-Incident-Id': created.id };
  const first = await (await fetch(`${base}/api/incidents/${created.id}/archive`, {
    method: 'POST',
    headers: { ...incidentHeaders, 'X-Op-Id': 'api-archive-1' },
    body: '{}',
  })).json();
  assert.equal(first.status, 'archived');
  const second = await (await fetch(`${base}/api/incidents/${created.id}/archive`, {
    method: 'POST',
    headers: { ...incidentHeaders, 'X-Op-Id': 'api-archive-1' },
    body: '{}',
  })).json();
  assert.equal(second.id, first.id);
  assert.equal(second.archived_at, first.archived_at);
});

test('并发手动归档只追加一条归档事件', async () => {
  const created = await (await fetch(`${base}/api/incidents`, {
    method: 'POST',
    headers: { ...H, 'X-Op-Id': 'api-create-concurrent-archive' },
    body: JSON.stringify({ actor_name: '测试员' }),
  })).json();
  const incidentHeaders = { ...H, 'X-Incident-Id': created.id };
  const responses = await Promise.all(Array.from({ length: 8 }, (_, index) => fetch(`${base}/api/incidents/${created.id}/archive`, {
    method: 'POST',
    headers: { ...incidentHeaders, 'X-Op-Id': `api-concurrent-archive-${index}` },
    body: '{}',
  })));
  assert.ok(responses.every((response) => response.status === 200));
  const timeline = await (await fetch(`${base}/api/incidents/${created.id}/timeline`, { headers: incidentHeaders })).json();
  assert.equal(timeline.events.filter((event) => event.type === 'incident_archived').length, 1);
});

test('GET /api/incidents 支持按归档状态筛选并按归档时间倒序', async () => {
  const archived = await (await fetch(`${base}/api/incidents?status=archived`, { headers: H })).json();
  assert.ok(archived.every((item) => item.status === 'archived'));
  for (let i = 1; i < archived.length; i++) {
    assert.ok(archived[i - 1].archived_at >= archived[i].archived_at);
  }
});

test('警情编号只读且同一分钟通过后缀区分', async () => {
  const a = db.createIncident({ createdAt: 946684800000 });
  const b = db.createIncident({ createdAt: a.created_at });
  assert.equal(b.number, a.number.replace('1#警情', '2#警情'));
  const rename = await fetch(`${base}/api/incidents/${a.id}`, {
    method: 'PATCH',
    headers: { ...H, 'X-Incident-Id': a.id },
    body: JSON.stringify({ number: '不允许覆盖', expected_version: a.version }),
  });
  assert.equal(rename.status, 200);
  assert.notEqual((await rename.json()).number, '不允许覆盖');
});;
