const test = require('node:test');
const assert = require('node:assert/strict');

process.env.WATCHDOG_DB_DRIVER = 'cloudbase';
process.env.CLOUDBASE_ENV_ID = 'test-env';
process.env.CLOUDBASE_API_KEY = 'test-api-key';

const requests = [];
global.fetch = async (_url, options) => {
  const body = JSON.parse(options.body);
  requests.push(body);
  if (/SELECT id FROM test_table/i.test(body.sql)) {
    return new Response(JSON.stringify([{ id: 'row-1' }]), { status: 200 });
  }
  return new Response('[]', { status: 200 });
};

const db = require('../src/db');

test('CloudBase PostgreSQL 驱动转换参数并返回行数据', async () => {
  await db.ready;
  const before = requests.length;
  const result = await db.executeSQL('SELECT id FROM test_table WHERE id = ? AND scene = ?', ['row-1', 'scene-a']);
  assert.deepEqual(result.rows, [{ id: 'row-1' }]);
  const request = requests[before];
  assert.match(request.sql, /id = 'row-1' AND scene = 'scene-a'/);
  assert.equal(request.params, undefined);
  assert.equal(request.role, 'cloudbase_postgres');
});
