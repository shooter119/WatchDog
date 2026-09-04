const { test, before, after, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-incidents-'));
process.env.WATCHDOG_DATA_DIR = tmpDir;

const app = require('../src/server');
const db = require('../src/db');

let server;
let base;

before(async () => {
  server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => new Promise((resolve) => server.close(resolve)));

afterEach(() => {
  for (const incident of db.listIncidents('active')) {
    db.archiveIncident(incident.id, { archivedBy: 'test-cleanup', now: Date.now() });
  }
});

const headers = (extra = {}) => ({
  'Content-Type': 'application/json',
  'X-Device-Id': 'incident-device-1',
  'X-Actor-Name': 'tester',
  ...extra,
});
const json = (response) => response.json();

async function createIncident(opId = `create-${Date.now()}-${Math.random()}`) {
  const response = await fetch(`${base}/api/incidents`, {
    method: 'POST',
    headers: headers({ 'X-Op-Id': opId }),
    body: JSON.stringify({ actor_name: '测试员' }),
  });
  assert.equal(response.status, 201);
  return json(response);
}

test('新建警情服务端限制 1 分钟内重复建档，并返回可加入的现有警情', async () => {
  const first = await createIncident('cooldown-first');
  const response = await fetch(`${base}/api/incidents`, {
    method: 'POST',
    headers: headers({ 'X-Op-Id': 'cooldown-second' }),
    body: JSON.stringify({ actor_name: '测试员' }),
  });
  assert.equal(response.status, 409);
  const body = await json(response);
  assert.equal(body.code, 'INCIDENT_CREATE_COOLDOWN');
  assert.equal(body.incident.id, first.id);
  assert.ok(body.retry_after_seconds > 0);
});

test('新建警情使用 UUID 主键、可读编号，并处理同一分钟编号冲突', async () => {
  const now = Date.now();
  const first = db.createIncident({ createdAt: now });
  const second = db.createIncident({ createdAt: now });
  assert.match(first.id, /^[0-9a-f-]{36}$/);
  const firstNumber = first.number.match(/^(\d{4}年\d{1,2}月\d{1,2}日\d{2}时\d{2}分)(\d+)#警情$/);
  const secondNumber = second.number.match(/^(\d{4}年\d{1,2}月\d{1,2}日\d{2}时\d{2}分)(\d+)#警情$/);
  assert.ok(firstNumber);
  assert.ok(secondNumber);
  assert.equal(secondNumber[1], firstNumber[1]);
  assert.equal(Number(secondNumber[2]), Number(firstNumber[2]) + 1);

  const created = await createIncident();
  assert.equal(created.status, 'active');
  assert.equal(created.display_name, created.number);
  assert.ok(Array.isArray(created.forces));
});

test('警情编号始终按东八区生成，不依赖服务器系统时区', () => {
  const incident = db.createIncident({
    id: 'shanghai-timezone-incident',
    createdAt: Date.UTC(2024, 0, 1, 0, 5),
  });
  assert.match(incident.number, /^2024年1月1日08时05分\d+#警情$/);
});

test('支持中文实名的 Base64 请求头，不因 HTTP 头编码失败', async () => {
  const utf8Headers = headers({ 'X-Op-Id': 'create-utf8-actor' });
  delete utf8Headers['X-Actor-Name'];
  utf8Headers['X-Actor-Name-B64'] = Buffer.from('李翔', 'utf8').toString('base64');
  const response = await fetch(`${base}/api/incidents`, {
    method: 'POST',
    headers: utf8Headers,
    body: '{}',
  });
  assert.equal(response.status, 201);
  const created = await json(response);
  const timeline = await json(await fetch(`${base}/api/incidents/${created.id}/timeline`, {
    headers: headers({ 'X-Incident-Id': created.id }),
  }));
  assert.equal(timeline.events[0].actor_name, '李翔');
});

test('新建警情拒绝复用其他类型事件的 client_op_id', async () => {
  const first = await createIncident('op-reuse-source');
  const sourceHeaders = headers({ 'X-Incident-Id': first.id, 'X-Op-Id': 'op-reused-for-create' });
  const note = await fetch(`${base}/api/notes`, {
    method: 'POST', headers: sourceHeaders, body: JSON.stringify({ text: '先占用操作 ID' }),
  });
  assert.equal(note.status, 201);
  const response = await fetch(`${base}/api/incidents`, {
    method: 'POST',
    headers: headers({ 'X-Op-Id': 'op-reused-for-create' }),
    body: JSON.stringify({ actor_name: '测试员' }),
  });
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, 'CLIENT_OP_ID_CONFLICT');
});

test('改名使用版本控制，未实名管理操作被拒绝', async () => {
  const incident = await createIncident();
  const noName = await fetch(`${base}/api/incidents/${incident.id}`, {
    method: 'PATCH',
    headers: headers({ 'X-Actor-Name': '' }),
    body: JSON.stringify({ title: '不应成功', expected_version: incident.version }),
  });
  assert.equal(noName.status, 403);

  const renamed = await json(await fetch(`${base}/api/incidents/${incident.id}`, {
    method: 'PATCH',
    headers: headers({ 'X-Op-Id': 'rename-1' }),
    body: JSON.stringify({ title: '幸福小区火灾', expected_version: incident.version }),
  }));
  assert.equal(renamed.title, '幸福小区火灾');

  const conflict = await fetch(`${base}/api/incidents/${incident.id}`, {
    method: 'PATCH',
    headers: headers({ 'X-Op-Id': 'rename-conflict' }),
    body: JSON.stringify({ title: '过期修改', expected_version: incident.version }),
  });
  assert.equal(conflict.status, 409);
  assert.equal((await json(conflict)).code, 'VERSION_CONFLICT');
});

test('参战力量按消防站汇总，保留快照并记录前后值，版本冲突返回 409', async () => {
  const incident = await createIncident();
  const stationList = await json(await fetch(`${base}/api/stations`, { headers: headers() }));
  assert.ok(stationList.some((station) => station.name === '龙翔路站'));

  const added = await json(await fetch(`${base}/api/incidents/${incident.id}/forces`, {
    method: 'POST',
    headers: headers({ 'X-Op-Id': 'force-add' }),
    body: JSON.stringify({ station_name: '龙翔路站', vehicle_count: 5, personnel_count: 25 }),
  }));
  assert.equal(added.station_name, '龙翔路站');
  assert.equal(added.version, 1);

  const updated = await json(await fetch(`${base}/api/incidents/${incident.id}/forces`, {
    method: 'POST',
    headers: headers({ 'X-Op-Id': 'force-update' }),
    body: JSON.stringify({ station_name: '龙翔路站', vehicle_count: 6, personnel_count: 30, expected_version: 1 }),
  }));
  assert.equal(updated.id, added.id);
  assert.equal(updated.version, 2);

  const conflict = await fetch(`${base}/api/incidents/${incident.id}/forces/${added.id}`, {
    method: 'PATCH',
    headers: headers({ 'X-Op-Id': 'force-conflict' }),
    body: JSON.stringify({ vehicle_count: 7, personnel_count: 35, expected_version: 1 }),
  });
  assert.equal(conflict.status, 409);

  const forces = await json(await fetch(`${base}/api/incidents/${incident.id}/forces`, { headers: headers() }));
  assert.equal(forces.length, 1);
  assert.equal(forces[0].vehicle_count, 6);
  assert.equal(forces[0].personnel_count, 30);
});

test('进退场、随手记和修订事件在时间线中各出现一次', async () => {
  const incident = await createIncident();
  const incidentHeaders = headers({ 'X-Incident-Id': incident.id });
  const entry = await json(await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: { ...incidentHeaders, 'X-Op-Id': 'entry-once' },
    body: JSON.stringify({ name: '李娜', pressure_mpa: 20 }),
  }));
  await fetch(`${base}/api/entries/${entry.id}/exit`, {
    method: 'POST',
    headers: { ...incidentHeaders, 'X-Op-Id': 'exit-once' },
  });
  const note = await json(await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: { ...incidentHeaders, 'X-Op-Id': 'note-once' },
    body: JSON.stringify({ text: '北侧水带铺设完成', category: '出水' }),
  }));
  await fetch(`${base}/api/notes/${note.id}`, {
    method: 'PATCH',
    headers: { ...incidentHeaders, 'X-Op-Id': 'note-revise' },
    body: JSON.stringify({ text: '北侧水带铺设完成，压力正常', category: '出水' }),
  });

  const timeline = await json(await fetch(`${base}/api/incidents/${incident.id}/timeline`, { headers: incidentHeaders }));
  assert.equal(timeline.events.filter((event) => event.type === 'entry').length, 1);
  assert.equal(timeline.events.filter((event) => event.type === 'exit').length, 1);
  assert.equal(timeline.events.filter((event) => event.type === 'note').length, 1);
  assert.equal(timeline.events.filter((event) => event.type === 'note_updated').length, 1);
  assert.ok(timeline.events.every((event, index) => index === 0 || event.occurred_at <= timeline.events[index - 1].occurred_at));
});

test('归档保留未确认离场人数，归档后现场数据只读且名称仍可改', async () => {
  const incident = await createIncident();
  const incidentHeaders = headers({ 'X-Incident-Id': incident.id });
  const entry = await json(await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: incidentHeaders,
    body: JSON.stringify({ name: '未确认离场', pressure_mpa: 20 }),
  }));
  const archived = await json(await fetch(`${base}/api/incidents/${incident.id}/archive`, {
    method: 'POST',
    headers: headers({ 'X-Incident-Id': incident.id, 'X-Op-Id': 'archive-manual' }),
    body: '{}',
  }));
  assert.equal(archived.status, 'archived');
  assert.equal(archived.unresolved_active_count, 1);
  assert.equal(archived.auto_archived, 0);

  const blocked = await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: incidentHeaders,
    body: JSON.stringify({ name: '归档后写入', pressure_mpa: 20 }),
  });
  assert.equal(blocked.status, 409);

  const renamed = await json(await fetch(`${base}/api/incidents/${incident.id}`, {
    method: 'PATCH',
    headers: headers({ 'X-Incident-Id': incident.id }),
    body: JSON.stringify({ title: '归档后正式名称', expected_version: archived.version }),
  }));
  assert.equal(renamed.title, '归档后正式名称');
  assert.ok(entry.id);
});

test('手动归档重复请求不会重复写归档事件', async () => {
  const incident = await createIncident('archive-event-once');
  const incidentHeaders = headers({ 'X-Incident-Id': incident.id });
  const responses = await Promise.all(Array.from({ length: 6 }, (_, index) => fetch(`${base}/api/incidents/${incident.id}/archive`, {
    method: 'POST',
    headers: { ...incidentHeaders, 'X-Op-Id': `archive-event-once-${index}` },
    body: '{}',
  })));
  assert.ok(responses.every((response) => response.status === 200));
  const timeline = await json(await fetch(`${base}/api/incidents/${incident.id}/timeline`, { headers: incidentHeaders }));
  assert.equal(timeline.events.filter((event) => event.type === 'incident_archived').length, 1);
});

test('12 小时自动归档和离线补传幂等', async () => {
  const now = Date.now();
  const stale = db.createIncident({ createdAt: now - 13 * 3600 * 1000 });
  db.createEntry({ id: 'stale-entry', scene: stale.id, name: '未离场', pressureMpa: 20, durationMin: 17, entryAtMs: stale.created_at, exitAtMs: stale.created_at + 17 * 60000 });
  assert.equal(db.archiveStaleIncidents({ now }), 1);
  const staleView = db.getIncident(stale.id);
  assert.equal(staleView.status, 'archived');
  assert.equal(staleView.auto_archived, 1);
  assert.equal(staleView.unresolved_active_count, 1);

  const incident = await createIncident();
  const offlineHeaders = headers({ 'X-Incident-Id': incident.id });
  const operation = {
    type: 'note',
    occurred_at: Date.now(),
    client_op_id: 'offline-note-1',
    payload: { note_id: 'offline-note-1', text: '断网期间记录', category: '其他' },
  };
  const first = await json(await fetch(`${base}/api/incidents/${incident.id}/offline-operations`, {
    method: 'POST',
    headers: offlineHeaders,
    body: JSON.stringify({ operations: [operation] }),
  }));
  assert.equal(first.results[0].accepted, true);
  const duplicate = await json(await fetch(`${base}/api/incidents/${incident.id}/offline-operations`, {
    method: 'POST',
    headers: offlineHeaders,
    body: JSON.stringify({ operations: [operation] }),
  }));
  assert.equal(duplicate.results[0].duplicate, true);
  assert.equal(db.listIncidentEvents(incident.id).filter((event) => event.client_op_id === 'offline-note-1').length, 1);
});

test('离线补传同一操作 ID 的内容变化会冲突且不重复写入', async () => {
  const incident = await createIncident();
  const offlineHeaders = headers({ 'X-Incident-Id': incident.id });
  const operation = {
    type: 'note',
    occurred_at: Date.now(),
    client_op_id: 'offline-note-conflict-1',
    payload: { note_id: 'offline-note-conflict-1', text: '第一次记录', category: '其他' },
  };
  const first = await json(await fetch(`${base}/api/incidents/${incident.id}/offline-operations`, {
    method: 'POST', headers: offlineHeaders, body: JSON.stringify({ operations: [operation] }),
  }));
  assert.equal(first.results[0].accepted, true);

  const changed = await json(await fetch(`${base}/api/incidents/${incident.id}/offline-operations`, {
    method: 'POST', headers: offlineHeaders,
    body: JSON.stringify({ operations: [{ ...operation, payload: { ...operation.payload, text: '篡改后的记录' } }] }),
  }));
  assert.equal(changed.results[0].accepted, false);
  assert.equal(changed.results[0].code, 'OPERATION_REQUEST_CONFLICT');
  assert.equal(db.listIncidentEvents(incident.id).filter((event) => event.client_op_id === operation.client_op_id).length, 1);
  assert.equal(db.listNotes({ scene: incident.id }).find((note) => note.id === operation.payload.note_id).text, '第一次记录');
});
