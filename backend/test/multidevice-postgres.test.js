const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { Pool } = require('pg');
const WebSocket = require('ws');
const path = require('node:path');

process.env.NODE_ENV = 'test';
process.env.WATCHDOG_DB_DRIVER = 'postgres';
process.env.WATCHDOG_SKIP_SEED = '1';
const admin = new Pool({ connectionString: process.env.DATABASE_URL || 'postgresql:///watchdog_test' });
const schema = `multidevice_${process.pid}_${Date.now()}`;
const children = [];
let store, db, base, peer, a, b, member;

async function start() {
  const port = 16000 + Math.floor(Math.random() * 20000);
  const child = spawn(process.execPath, ['src/server.js'], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, PORT: String(port), API_TOKEN: '', WATCHDOG_ENTRY_VERSION_REQUIRED: '1', WATCHDOG_SESSION_AUTH_REQUIRED: '1', WATCHDOG_MEMBER_AUTH_REQUIRED: '1', WATCHDOG_UNIT_AUTH_REQUIRED: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  children.push(child);
  let logs = '';
  child.stdout.on('data', chunk => { logs += chunk; });
  child.stderr.on('data', chunk => { logs += chunk; });
  const url = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 80; i++) {
    try { if ((await fetch(url + '/api/health')).ok) return url; } catch (_) {}
    if (child.exitCode != null) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error('测试后端未启动: ' + logs);
}
async function request(route, { token = a, data, method, op = randomUUID(), origin = base, incident = 'incident' } = {}) {
  const response = await fetch(origin + route, { method: method || (data === undefined ? 'GET' : 'POST'), headers: {
    'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}),
    'X-Incident-Id': incident, 'X-Op-Id': op,
  }, ...(data !== undefined ? { body: JSON.stringify(data) } : {}) });
  return { status: response.status, body: await response.json() };
}
async function login(device, name = '队员') {
  const result = await fetch(base + '/api/auth/verify', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Device-Id': device }, body: JSON.stringify({ unit_name: '并发测试单位', unit_code: '1234', real_name: name, device_name: device, platform: 'Android' }) });
  assert.equal(result.status, 200);
  return (await result.json()).session_token;
}
async function entry(name = randomUUID()) {
  const result = await request('/api/entries', { data: { name, pressure_mpa: 25 } });
  assert.equal(result.status, 201, JSON.stringify(result.body));
  return result.body;
}
function offline(opId, type, payload) {
  return { client_op_id: opId, type, payload, occurred_at: Date.now(), owner_member_id: member.id, owner_unit_id: 'unit' };
}

before(async () => {
  await admin.query(`CREATE SCHEMA "${schema}"`);
  const url = new URL(process.env.DATABASE_URL || 'postgresql:///watchdog_test');
  url.searchParams.set('options', `-c search_path=${schema}`);
  process.env.DATABASE_URL = url.toString();
  store = require('../src/postgres-store'); db = require('../src/db');
  await db.ready;
  await store.query("INSERT INTO units(id,name,verification_code,created_at,updated_at) VALUES('unit','并发测试单位','1234',$1,$1)", [Date.now()]);
  member = await db.addUnitMember({ unitId: 'unit', realName: '队员' });
  await db.addUnitMember({ unitId: 'unit', realName: '另一成员' });
  await db.createIncident({ id: 'incident', unitId: 'unit', createdAt: Date.now() });
  base = await start(); peer = await start();
  a = await login('phone-a'); b = await login('tablet-b');
});
after(async () => {
  await Promise.all(children.map(async child => { if (child.exitCode == null) { const done = once(child, 'exit'); child.kill(); await done; } }));
  await store?.close();
  await admin.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`); await admin.end();
});

test('同成员两设备并行、版本并发只成功一次、成功请求重试幂等', async () => {
  assert.equal((await request('/api/incidents', { token: b })).status, 200);
  const e = await entry();
  const opA = randomUUID(), opB = randomUUID();
  const data = { pressure_mpa: 20, expected_version: e.version };
  const results = await Promise.all([
    request(`/api/entries/${e.id}`, { method: 'PATCH', data, op: opA }),
    request(`/api/entries/${e.id}`, { token: b, origin: peer, method: 'PATCH', data, op: opB }),
  ]);
  assert.deepEqual(results.map(r => r.status).sort(), [200, 409]);
  const conflict = results.find(r => r.status === 409);
  assert.equal(conflict.body.code, 'VERSION_CONFLICT');
  const winner = results[0].status === 200 ? opA : opB;
  const retry = await request(`/api/entries/${e.id}`, { token: winner === opA ? a : b, method: 'PATCH', data, op: winner });
  assert.equal(retry.status, 200);
  assert.equal(retry.body.version, 2);
  const samples = await db.listPressureSamples(e.id);
  assert.equal(samples.length, 2);
});

test('旧版关键写入明确要求升级，读取可用；已出场不接受压力', async () => {
  const e = await entry();
  const legacy = await request(`/api/entries/${e.id}`, { method: 'PATCH', data: { pressure_mpa: 18 } });
  assert.equal(legacy.status, 428); assert.equal(legacy.body.code, 'CLIENT_UPGRADE_REQUIRED');
  assert.equal((await request('/api/entries')).status, 200);
  const exited = await request(`/api/entries/${e.id}/exit`, { data: { expected_version: 1 } });
  assert.equal(exited.status, 200);
  assert.equal((await request(`/api/entries/${e.id}/exit`, { data: { expected_version: 1 } })).status, 200);
  assert.equal((await request(`/api/entries/${e.id}`, { method: 'PATCH', data: { pressure_mpa: 18, expected_version: 2 } })).body.code, 'ENTRY_EXITED');
});

test('压力和出场并发只应用一种状态转换', async () => {
  const e = await entry();
  const results = await Promise.all([
    request(`/api/entries/${e.id}`, { method: 'PATCH', data: { pressure_mpa: 17, expected_version: 1 } }),
    request(`/api/entries/${e.id}/exit`, { token: b, data: { expected_version: 1 } }),
  ]);
  assert.deepEqual(results.map(r => r.status).sort(), [200, 409]);
  assert.equal((await db.getEntry(e.id)).version, 2);
});

test('并发同名进场无法通过 force 绕过，改名亦有版本保护', async () => {
  const name = '同名-' + randomUUID();
  const results = await Promise.all([request('/api/entries', { data: { name, pressure_mpa: 25, force: true } }), request('/api/entries', { token: b, data: { name, pressure_mpa: 25, force: true } })]);
  assert.deepEqual(results.map(r => r.status).sort(), [201, 409]);
  const e = results.find(r => r.status === 201).body;
  const changed = await request(`/api/entries/${e.id}`, { method: 'PATCH', data: { name: '改名-' + randomUUID(), expected_version: 1 } });
  assert.equal(changed.status, 200); assert.equal(changed.body.version, 2);
  assert.equal((await request(`/api/entries/${e.id}`, { method: 'PATCH', data: { name, expected_version: 1 } })).status, 409);
});

test('离线旧压力、前序冲突和身份不符均不覆盖；独立随手记继续成功', async () => {
  const e = await entry();
  await request(`/api/entries/${e.id}`, { method: 'PATCH', data: { pressure_mpa: 19, expected_version: 1 } });
  const first = randomUUID();
  const operations = [offline(first, 'pressure', { entry_id: e.id, pressure_mpa: 23, expected_version: 1 }), offline(randomUUID(), 'exit', { entry_id: e.id, predecessor_op_id: first }), offline(randomUUID(), 'note', { text: '独立随手记' })];
  const result = await request('/api/incidents/incident/offline-operations', { data: { operations } });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body.results.map(r => r.accepted), [false, false, true]);
  assert.equal(result.body.results[0].code, 'VERSION_CONFLICT');
  assert.equal(result.body.results[1].code, 'DEPENDENCY_CONFLICT');
  assert.equal((await db.getEntry(e.id)).pressure_mpa, 19);
  const wrong = offline(randomUUID(), 'note', { text: '不应上传' }); wrong.owner_member_id = 'other';
  assert.equal((await request('/api/incidents/incident/offline-operations', { data: { operations: [wrong] } })).body.results[0].code, 'OFFLINE_OWNER_MISMATCH');
});

test('连续离线进场压力出场通过前序版本串联；旧时间戳被拒绝', async () => {
  const id = randomUUID(), op = randomUUID(), pressureOp = randomUUID();
  const now = Date.now();
  const operations = [
    { ...offline(op, 'entry', { entry_id: id, name: id, pressure_mpa: 25 }), occurred_at: now - 3000 },
    { ...offline(pressureOp, 'pressure', { entry_id: id, pressure_mpa: 21, predecessor_op_id: op }), occurred_at: now - 2000 },
    { ...offline(randomUUID(), 'exit', { entry_id: id, predecessor_op_id: pressureOp }), occurred_at: now - 1000 },
  ];
  const result = await request('/api/incidents/incident/offline-operations', { data: { operations } });
  assert.deepEqual(result.body.results.map(r => r.accepted), [true, true, true], JSON.stringify(result.body));
  const e = await db.getEntry(id); assert.equal(e.version, 3); assert.ok(e.exited_at);
  const stale = await entry();
  const earlier = { ...offline(randomUUID(), 'pressure', { entry_id: stale.id, pressure_mpa: 29, expected_version: 1 }), occurred_at: stale.entry_at - 1000 };
  assert.equal((await request('/api/incidents/incident/offline-operations', { data: { operations: [earlier] } })).body.results[0].code, 'STALE_PRESSURE');
});

test('设备列表不泄漏凭据，跨成员撤销被拒绝，撤销跨实例关闭长连接与旧Token', async () => {
  const bOld = b; b = await login('tablet-b');
  const other = await login('other-phone', '另一成员');
  const devices = await request('/api/auth/devices');
  assert.equal(devices.status, 200); assert.equal(devices.body.length, 2);
  assert.ok(!JSON.stringify(devices.body).includes('token'));
  const target = devices.body.find(d => !d.current);
  assert.equal((await request(`/api/auth/devices/${target.id}/revoke`, { token: other, data: {} })).status, 404);
  const socket = new WebSocket(peer.replace('http', 'ws') + '/api/realtime', { headers: { Authorization: `Bearer ${b}` } });
  await once(socket, 'open');
  const voice = new WebSocket(peer.replace('http', 'ws') + '/api/asr/stream', { headers: { Authorization: `Bearer ${b}`, 'X-Incident-Id': 'incident' } });
  await once(voice, 'open');
  const voiceClosed = once(voice, 'close');
  const closed = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { socket.terminate(); reject(new Error('撤销后连接未及时关闭')); }, 5000);
    socket.once('close', code => { clearTimeout(timeout); resolve(code); });
  });
  const revoked = await request(`/api/auth/devices/${target.id}/revoke`, { data: {} });
  assert.equal(revoked.status, 200); assert.ok(revoked.body.revoked >= 2);
  assert.equal(await closed, 4003);
  assert.equal((await voiceClosed)[0], 4003);
  assert.equal((await request('/api/incidents', { token: b })).status, 401);
  assert.equal((await request('/api/auth/refresh', { token: bOld, data: {} })).status, 401);
  assert.equal((await request('/api/incidents')).status, 200);
  assert.ok((await store.query('SELECT * FROM auth_device_audit')).rows.length >= 2);
});


test('退出其他设备保留本机并拒绝操作本机，其他成员不受影响', async () => {
  const c = await login('device-c'), d = await login('device-d');
  const other = await login('another-member-device', '另一成员');
  const current = (await request('/api/auth/devices')).body.find(item => item.current);
  assert.equal((await request(`/api/auth/devices/${current.id}/revoke`, { data: {} })).body.code, 'CURRENT_DEVICE');
  const revoked = await request('/api/auth/devices/revoke-others', { data: {} });
  assert.equal(revoked.status, 200); assert.ok(revoked.body.revoked >= 2);
  assert.equal((await request('/api/incidents', { token: c })).status, 401);
  assert.equal((await request('/api/incidents', { token: d })).status, 401);
  assert.equal((await request('/api/incidents', { token: other })).status, 200);
  assert.equal((await request('/api/incidents')).status, 200);
});

test('事务失败回滚读数与采样，原记录可按同版本重试', async () => {
  const e = await entry();
  await assert.rejects(db.updatePressureWithEvent({ entryId: e.id, scene: 'incident', pressureMpa: 18, reportedAtMs: Date.now(), expectedVersion: 1, incidentId: 'incident', calcConfig: { cylinderVolL: 6.8, consumptionLpm: 80 }, event: { incidentId: 'missing-incident', type: 'pressure', payload: { entry_id: e.id } } }));
  assert.equal((await db.getEntry(e.id)).version, 1);
  assert.equal((await db.listPressureSamples(e.id)).length, 1);
  assert.equal((await request(`/api/entries/${e.id}`, { method: 'PATCH', data: { pressure_mpa: 18, expected_version: 1 } })).status, 200);
});

test('成功请求在警情归档后重试仍能确认结果，新写入被拒绝', async () => {
  await db.createIncident({ id: 'archived-test', unitId: 'unit', createdAt: Date.now() });
  const e = (await request('/api/entries', { incident: 'archived-test', data: { name: '归档幂等测试', pressure_mpa: 25 } })).body;
  const op = randomUUID(), data = { pressure_mpa: 18, expected_version: 1 };
  assert.equal((await request(`/api/entries/${e.id}`, { incident: 'archived-test', op, method: 'PATCH', data })).status, 200);
  await db.archiveIncident('archived-test');
  assert.equal((await request(`/api/entries/${e.id}`, { incident: 'archived-test', op, method: 'PATCH', data })).status, 200);
  assert.equal((await request(`/api/entries/${e.id}`, { incident: 'archived-test', method: 'PATCH', data: { pressure_mpa: 16, expected_version: 2 } })).status, 409);
});
