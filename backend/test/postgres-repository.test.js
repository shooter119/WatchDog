const { test, before } = require('node:test');
const assert = require('node:assert/strict');

process.env.WATCHDOG_DB_DRIVER = 'cloudbase';
process.env.CLOUDBASE_ENV_ID = 'pg-test-env';
process.env.CLOUDBASE_API_KEY = 'service-role-test-key';
process.env.CLOUDBASE_SKIP_SEED = '1';

const tables = new Map();
const uniqueColumns = {
  entries: ['id'], firefighters: ['id', 'name'], hotwords: ['id', 'word'], incidents: ['id', 'number'],
  incident_events: ['id', 'client_op_id'], stations: ['id', 'name', 'normalized_name'],
  incident_forces: ['id'], notes: ['id'], pressure_samples: ['id'], chat_messages: ['id'],
  user_settings: ['user_id', 'scene', 'key'], device_profiles: ['device_id'], logs: ['id'],
  units: ['id', 'name', 'verification_code'], unit_members: ['id', 'unit_id', 'real_name'],
  auth_sessions: ['id', 'token_hash'], operation_ledger: ['unit_id,client_op_id'],
};

function tableRows(table) {
  if (!tables.has(table)) tables.set(table, []);
  return tables.get(table);
}

function response(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json' } });
}

function matches(url, row) {
  for (const [column, raw] of url.searchParams.entries()) {
    if (['select', 'order', 'limit', 'offset', 'on_conflict'].includes(column)) continue;
    const [op, ...rest] = raw.split('.');
    const value = rest.join('.');
    const actual = row[column];
    if (op === 'eq' && String(actual) !== value) return false;
    if (op === 'is' && value === 'null' && actual != null) return false;
    if (op === 'gte' && Number(actual) < Number(value)) return false;
    if (op === 'lte' && Number(actual) > Number(value)) return false;
    if (op === 'lt' && Number(actual) >= Number(value)) return false;
    if (op === 'gt' && Number(actual) <= Number(value)) return false;
    if (op === 'in' && !value.slice(1, -1).split(',').includes(String(actual))) return false;
  }
  return true;
}

function sorted(url, rows) {
  const order = url.searchParams.get('order');
  if (!order) return rows;
  return [...rows].sort((a, b) => {
    for (const item of order.split(',')) {
      const [column, direction = 'asc'] = item.split('.');
      if (a[column] === b[column]) continue;
      const result = a[column] > b[column] ? 1 : -1;
      return direction === 'desc' ? -result : result;
    }
    return 0;
  });
}

global.fetch = async (urlValue, options) => {
  const url = new URL(urlValue);
  const parts = url.pathname.split('/').filter(Boolean);
  const table = parts[parts.length - 1];
  const rows = tableRows(table);
  if (options.method === 'GET') {
    let result = sorted(url, rows.filter((row) => matches(url, row)));
    const offset = Number(url.searchParams.get('offset') || 0);
    const limit = Number(url.searchParams.get('limit') || result.length);
    result = result.slice(offset, offset + limit);
    return response(result);
  }
  if (options.method === 'POST') {
    const incoming = JSON.parse(options.body);
    const values = Array.isArray(incoming) ? incoming : [incoming];
    const conflictColumns = (url.searchParams.get('on_conflict') || '').split(',').filter(Boolean);
    const returned = [];
    for (const value of values) {
      const columns = conflictColumns.length ? conflictColumns : uniqueColumns[table] || ['id'];
      const existing = rows.find((row) => columns.every((column) => value[column] != null && row[column] === value[column]));
      if (existing) {
        if (options.headers.Prefer.includes('resolution=ignore-duplicates')) continue;
        if (options.headers.Prefer.includes('resolution=merge-duplicates')) Object.assign(existing, value);
        else return response({ message: 'duplicate key value violates unique constraint' }, 409);
        returned.push(existing);
        continue;
      }
      const copy = { ...value };
      if (table === 'pressure_samples' && copy.id == null) copy.id = rows.length + 1;
      rows.push(copy);
      returned.push(copy);
    }
    return response(returned, 201);
  }
  if (options.method === 'PATCH') {
    const values = JSON.parse(options.body);
    const changed = rows.filter((row) => matches(url, row));
    changed.forEach((row) => Object.assign(row, values));
    return response(changed);
  }
  if (options.method === 'DELETE') {
    const removed = rows.filter((row) => matches(url, row));
    tables.set(table, rows.filter((row) => !matches(url, row)));
    return response(removed);
  }
  return response({ message: 'unsupported method' }, 405);
};

const db = require('../src/db');

before(async () => db.ready);

test('PostgreSQL 仓储保留警情、事件幂等和进退场行为', async () => {
  const incident = await db.createIncident({ createdBy: 'test-device', createdAt: 1000 });
  assert.equal(incident.status, 'active');

  const firstEvent = await db.appendIncidentEvent({
    incidentId: incident.id, type: 'incident_created', clientOpId: 'op-1', payload: { title: '测试' },
  });
  const duplicateEvent = await db.appendIncidentEvent({
    incidentId: incident.id, type: 'incident_created', clientOpId: 'op-1', payload: { title: '不同内容' },
  });
  assert.equal(duplicateEvent.id, firstEvent.id);
  assert.deepEqual(duplicateEvent.payload, { title: '测试' });

  const entry = await db.createEntry({
    id: 'entry-1', scene: incident.id, name: '张三', pressureMpa: 20,
    durationMin: 17, entryAtMs: 2000, exitAtMs: 100000,
  });
  assert.equal(entry.name, '张三');
  assert.equal((await db.listEntries({ activeOnly: true, scene: incident.id })).length, 1);
  const exited = await db.markExited(entry.id, 3000);
  assert.equal(exited.exited_at, 3000);
  assert.equal((await db.listEntries({ activeOnly: true, scene: incident.id })).length, 0);
});

test('PostgreSQL 警情列表将单位过滤和上限下推到仓储', async () => {
  await db.createIncident({ id: 'unit-a-incident-1', unitId: 'unit-a', createdAt: 3000 });
  await db.createIncident({ id: 'unit-a-incident-2', unitId: 'unit-a', createdAt: 4000 });
  await db.createIncident({ id: 'unit-b-incident-1', unitId: 'unit-b', createdAt: 5000 });
  const rows = await db.listIncidents('active', { unitId: 'unit-a', limit: 1 });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].unit_id, 'unit-a');
});

test('PostgreSQL 警情列表分页将 offset 下推并保持单位边界', async () => {
  await db.createIncident({ id: 'unit-page-1', unitId: 'unit-page', createdAt: 1000 });
  await db.createIncident({ id: 'unit-page-2', unitId: 'unit-page', createdAt: 2000 });
  await db.createIncident({ id: 'unit-page-3', unitId: 'unit-page', createdAt: 3000 });
  const first = await db.listIncidents('active', { unitId: 'unit-page', limit: 2, offset: 0 });
  const second = await db.listIncidents('active', { unitId: 'unit-page', limit: 2, offset: 2 });
  assert.equal(first.length, 2);
  assert.equal(second.length, 1);
  assert.ok([...first, ...second].every((item) => item.unit_id === 'unit-page'));
});

test('PostgreSQL 参战力量列表支持按警情批量读取', async () => {
  tables.set('incident_forces', [
    { id: 'force-pg-1', incident_id: 'incident-pg-a', station_name: '一站' },
    { id: 'force-pg-2', incident_id: 'incident-pg-b', station_name: '二站' },
  ]);
  const rows = await db.listIncidentForcesBatch(['incident-pg-a', 'incident-pg-b']);
  assert.equal(rows.length, 2);
});

test('PostgreSQL 认证仓储保留成员角色并拒绝过期/已撤销会话', async () => {
  tableRows('unit_members').push({
    id: 'member-pg-1', unit_id: 'unit-pg', real_name: '管理员', role: 'manager', status: 'active',
  });
  const member = await db.findUnitMember('unit-pg', '管理员');
  assert.equal(member.role, 'manager');

  const expired = await db.createAuthSession({
    id: 'session-pg-expired', tokenHash: 'hash-pg-expired', unitId: 'unit-pg', memberId: member.id,
    deviceId: 'device-pg', realName: member.real_name, role: member.role,
    expiresAt: Date.now() - 1,
  });
  assert.equal(expired.id, 'session-pg-expired');
  assert.equal(await db.getAuthSession('hash-pg-expired'), undefined);

  await db.createAuthSession({
    id: 'session-pg-current', tokenHash: 'hash-pg-current', unitId: 'unit-pg', memberId: member.id,
    deviceId: 'device-pg', realName: member.real_name, role: member.role,
    expiresAt: Date.now() + 60_000,
  });
  assert.equal((await db.getAuthSession('hash-pg-current')).role, 'manager');
  assert.equal(await db.revokeAuthSession('hash-pg-current'), 1);
  assert.equal(await db.getAuthSession('hash-pg-current'), undefined);
});

test('PostgreSQL 操作账本按单位和操作号保留请求摘要与结果', async () => {
  const first = await db.beginOperation({
    unitId: 'unit-ledger-pg', clientOpId: 'ledger-pg-1', incidentId: 'incident-pg',
    operationType: 'entry', requestHash: 'hash-pg-a', actorName: '甲',
  });
  assert.equal(first.status, 'pending');
  assert.equal(first.created, true);
  const duplicate = await db.beginOperation({
    unitId: 'unit-ledger-pg', clientOpId: 'ledger-pg-1', incidentId: 'incident-pg',
    operationType: 'entry', requestHash: 'hash-pg-b', actorName: '乙',
  });
  assert.equal(duplicate.request_hash, 'hash-pg-a');
  assert.equal(await db.completeOperation({ unitId: 'unit-ledger-pg', clientOpId: 'ledger-pg-1', requestHash: 'hash-pg-b', result: { id: 'wrong' } }), 0);
  assert.equal(await db.completeOperation({ unitId: 'unit-ledger-pg', clientOpId: 'ledger-pg-1', requestHash: 'hash-pg-a', result: { id: 'entry-pg-1' }, responseStatus: 201, eventId: 'event-pg-1' }), 1);
  const completed = await db.getOperation('unit-ledger-pg', 'ledger-pg-1');
  assert.equal(completed.status, 'succeeded');
  assert.equal(JSON.parse(completed.result_json).id, 'entry-pg-1');
  assert.equal(completed.response_status, 201);
});

test('PostgreSQL 仓储的出场状态转换只成功一次', async () => {
  tableRows('entries').push({ id: 'entry-exit-once', scene: 'incident-pg', exited_at: null });
  const first = await db.markExitedIfActive('entry-exit-once', 1000);
  const second = await db.markExitedIfActive('entry-exit-once', 2000);
  assert.equal(first.changed, true);
  assert.equal(second.changed, false);
  assert.equal(second.entry.exited_at, 1000);
});
