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
  units: ['id', 'name', 'verification_code'],
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
