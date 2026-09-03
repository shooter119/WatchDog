const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

process.env.WATCHDOG_DB_DRIVER = 'postgres';
process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgresql:///watchdog_test';
process.env.WATCHDOG_SKIP_SEED = '1';

const db = require('../src/db');
const store = require('../src/postgres-store');

async function seedUnit(id) {
  await store.query(`
    INSERT INTO units (id, name, verification_code, created_at, updated_at)
    VALUES ($1, $2, $3, $4, $4)
    ON CONFLICT (id) DO NOTHING
  `, [id, `测试单位-${id}`, `code-${id}`.slice(0, 32), Date.now()]);
}

before(async () => {
  await db.ready;
  await store.query(`TRUNCATE TABLE
    sync_events, sync_streams, incident_events, operation_ledger, pressure_samples,
    entries, notes, incident_forces, incidents, auth_sessions, unit_members,
    firefighters, hotwords, device_profiles, user_settings, logs, chat_messages,
    stations, units CASCADE`);
  await seedUnit('unit-test');
});

after(async () => {
  await store.close();
});

test('PostgreSQL 仓储保留警情、事件幂等和进退场行为', async () => {
  const incident = await db.createIncident({ unitId: 'unit-test', createdBy: 'test-device', createdAt: 1000 });
  assert.equal(incident.status, 'active');
  const firstEvent = await db.appendIncidentEvent({ incidentId: incident.id, type: 'incident_created', clientOpId: 'op-1', payload: { title: '测试' } });
  const duplicateEvent = await db.appendIncidentEvent({ incidentId: incident.id, type: 'incident_created', clientOpId: 'op-1', payload: { title: '不同内容' } });
  assert.equal(duplicateEvent.id, firstEvent.id);
  assert.deepEqual(duplicateEvent.payload, { title: '测试' });
  assert.equal(firstEvent.sync.sequence, '1');

  const entry = await db.createEntry({ id: 'entry-1', scene: incident.id, name: '张三', pressureMpa: 20, durationMin: 17, entryAtMs: 2000, exitAtMs: 100000 });
  assert.equal(entry.name, '张三');
  assert.equal((await db.listEntries({ activeOnly: true, scene: incident.id })).length, 1);
  const exited = await db.markExited(entry.id, 3000);
  assert.equal(Number(exited.exited_at), 3000);
  assert.equal((await db.listEntries({ activeOnly: true, scene: incident.id })).length, 0);
});

test('PostgreSQL 警情列表将单位过滤和上限下推到仓储', async () => {
  await seedUnit('unit-a');
  await seedUnit('unit-b');
  await db.createIncident({ id: 'unit-a-incident-1', unitId: 'unit-a', createdAt: 3000 });
  await db.createIncident({ id: 'unit-a-incident-2', unitId: 'unit-a', createdAt: 4000 });
  await db.createIncident({ id: 'unit-b-incident-1', unitId: 'unit-b', createdAt: 5000 });
  const rows = await db.listIncidents('active', { unitId: 'unit-a', limit: 1 });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].unit_id, 'unit-a');
});

test('PostgreSQL 警情列表分页将 offset 下推并保持单位边界', async () => {
  await seedUnit('unit-page');
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
  await seedUnit('unit-force');
  const incidentA = await db.createIncident({ id: 'incident-pg-a', unitId: 'unit-force', createdAt: 1000 });
  const incidentB = await db.createIncident({ id: 'incident-pg-b', unitId: 'unit-force', createdAt: 2000 });
  await db.upsertIncidentForce({ id: 'force-pg-1', incidentId: incidentA.id, stationName: '一站' });
  await db.upsertIncidentForce({ id: 'force-pg-2', incidentId: incidentB.id, stationName: '二站' });
  const rows = await db.listIncidentForcesBatch([incidentA.id, incidentB.id]);
  assert.equal(rows.length, 2);
});

test('PostgreSQL 认证仓储保留成员角色并拒绝过期/已撤销会话', async () => {
  await seedUnit('unit-auth');
  const member = await db.addUnitMember({ id: 'member-pg-1', unitId: 'unit-auth', realName: '管理员', role: 'manager' });
  assert.equal(member.role, 'manager');
  const expired = await db.createAuthSession({ id: 'session-pg-expired', tokenHash: 'hash-pg-expired', unitId: 'unit-auth', memberId: member.id, deviceId: 'device-pg', realName: member.real_name, role: member.role, expiresAt: Date.now() - 1 });
  assert.equal(expired.id, 'session-pg-expired');
  assert.equal(await db.getAuthSession('hash-pg-expired'), undefined);
  await db.createAuthSession({ id: 'session-pg-current', tokenHash: 'hash-pg-current', unitId: 'unit-auth', memberId: member.id, deviceId: 'device-pg', realName: member.real_name, role: member.role, expiresAt: Date.now() + 60_000 });
  assert.equal((await db.getAuthSession('hash-pg-current')).role, 'manager');
  assert.equal(await db.revokeAuthSession('hash-pg-current'), 1);
  assert.equal(await db.getAuthSession('hash-pg-current'), undefined);
});

test('PostgreSQL 操作账本按单位和操作号保留请求摘要与结果', async () => {
  await seedUnit('unit-ledger-pg');
  const first = await db.beginOperation({ unitId: 'unit-ledger-pg', clientOpId: 'ledger-pg-1', operationType: 'entry', requestHash: 'hash-pg-a', actorName: '甲' });
  assert.equal(first.status, 'pending');
  assert.equal(first.created, true);
  const duplicate = await db.beginOperation({ unitId: 'unit-ledger-pg', clientOpId: 'ledger-pg-1', operationType: 'entry', requestHash: 'hash-pg-b', actorName: '乙' });
  assert.equal(duplicate.request_hash, 'hash-pg-a');
  assert.equal(await db.completeOperation({ unitId: 'unit-ledger-pg', clientOpId: 'ledger-pg-1', requestHash: 'hash-pg-b', result: { id: 'wrong' } }), 0);
  assert.equal(await db.completeOperation({ unitId: 'unit-ledger-pg', clientOpId: 'ledger-pg-1', requestHash: 'hash-pg-a', result: { id: 'entry-pg-1' }, responseStatus: 201, eventId: 'event-pg-1' }), 1);
  const completed = await db.getOperation('unit-ledger-pg', 'ledger-pg-1');
  assert.equal(completed.status, 'succeeded');
  assert.equal((typeof completed.result_json === 'string' ? JSON.parse(completed.result_json) : completed.result_json).id, 'entry-pg-1');
  assert.equal(completed.response_status, 201);
});

test('PostgreSQL 仓储的出场状态转换只成功一次', async () => {
  await seedUnit('unit-exit');
  const incident = await db.createIncident({ id: 'incident-pg-exit', unitId: 'unit-exit', createdAt: 1000 });
  await db.createEntry({ id: 'entry-exit-once', scene: incident.id, name: '张三', pressureMpa: 20, durationMin: 1, entryAtMs: 1000, exitAtMs: 2000 });
  const first = await db.markExitedIfActive('entry-exit-once', 1000);
  const second = await db.markExitedIfActive('entry-exit-once', 2000);
  assert.equal(first.changed, true);
  assert.equal(second.changed, false);
  assert.equal(Number(second.entry.exited_at), 1000);
});
