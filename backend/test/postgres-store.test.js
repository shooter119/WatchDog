const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');

process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgresql:///watchdog_test';
const store = require('../src/postgres-store');

before(() => store.ready);
after(() => store.close());

test('标准 PostgreSQL 仓储限制标识符并使用参数化值', async () => {
  await assert.rejects(
    () => store.select('entries; DROP TABLE units', {}),
    /未知数据表/,
  );
  const rows = await store.query('SELECT $1::text AS value', ["a'b"]);
  assert.equal(rows.rows[0].value, "a'b");
});

test('数据库事务失败时回滚业务表和实时事件', async () => {
  const id = `tx-${randomUUID()}`;
  await assert.rejects(() => store.transaction(async () => {
    await store.query('CREATE TEMP TABLE watchdog_tx_probe (id TEXT PRIMARY KEY)');
    await store.query('INSERT INTO watchdog_tx_probe (id) VALUES ($1)', [id]);
    throw new Error('故障注入');
  }), /故障注入/);
  const result = await store.query(
    'SELECT to_regclass($1) AS table_name',
    ['watchdog_tx_probe'],
  );
  assert.equal(result.rows[0].table_name, null);
});

test('迁移后的同步流按单位和警情使用独立连续游标', async () => {
  const unitId = `sync-test-${randomUUID()}`;
  await store.query('INSERT INTO units (id, name, verification_code, created_at, updated_at) VALUES ($1,$2,$3,$4,$4)', [unitId, unitId, unitId, Date.now()]);
  await store.query('INSERT INTO sync_streams (stream_key, last_sequence) VALUES ($1, 1), ($2, 2)', [`unit:${unitId}`, `incident:${unitId}`]);
  const rows = await store.select('sync_streams', { filters: { stream_key: { op: 'in', value: [`unit:${unitId}`, `incident:${unitId}`] } }, order: 'stream_key.asc' });
  assert.deepEqual(rows.map((row) => Number(row.last_sequence)), [2, 1]);
  await store.query('DELETE FROM units WHERE id = $1', [unitId]);
});

test('PostgreSQL LISTEN/NOTIFY 可收到提交后的同步事件通知', async () => {
  let notification;
  const marker = `probe-${randomUUID()}`;
  const stop = await store.listenSync((payload) => {
    if (payload?.stream_key === marker) notification = payload;
  });
  await store.query("SELECT pg_notify('watchdog_sync', $1)", [JSON.stringify({ stream_key: marker, sequence: '7' })]);
  for (let i = 0; i < 200 && !notification; i++) await new Promise((resolve) => setTimeout(resolve, 10));
  await stop();
  assert.deepEqual(notification, { stream_key: marker, sequence: '7' });
});
