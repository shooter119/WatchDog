const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { Pool } = require('pg');

process.env.WATCHDOG_DB_DRIVER = 'postgres';
process.env.WATCHDOG_SKIP_SEED = '1';

const baseUrl = process.env.DATABASE_URL || 'postgresql:///watchdog_test';
const pool = new Pool({ connectionString: baseUrl });
const schema = `video_resources_${process.pid}_${Date.now()}`;
let store;
let resources;
let server;
let base;

async function request(path, { member, body, method = 'GET' } = {}) {
  const headers = {
    'X-Test-Member': member,
    Origin: 'https://fireman119.xyz',
  };
  if (body) headers['Content-Type'] = 'application/json';
  return fetch(base + path, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
}

before(async () => {
  await pool.query(`CREATE SCHEMA "${schema}"`);
  const url = new URL(baseUrl);
  url.searchParams.set('options', `-c search_path=${schema}`);
  process.env.DATABASE_URL = url.toString();
  store = require('../src/postgres-store');
  await store.ready;
  await store.query(
    "INSERT INTO units(id,name,verification_code,created_at,updated_at) VALUES('one','单位一','1',1,1),('two','单位二','2',1,1)",
  );
  await store.query(
    "INSERT INTO unit_members(id,unit_id,real_name,role,created_at,updated_at) VALUES('manager','one','管理员','manager',1,1),('reader','one','成员','member',1,1),('other','two','其他管理员','admin',1,1)",
  );
  resources = require('../src/video-resources').createVideoResources(store);
  const app = require('express')();
  app.use(require('express').json());
  app.use('/api/video-resources', (req, res, next) => {
    const member = req.get('X-Test-Member');
    req.auth = {
      memberId: member,
      role: member === 'manager'
        ? 'manager'
        : member === 'other'
          ? 'admin'
          : 'member',
    };
    req.unit = { id: member === 'other' ? 'two' : 'one', name: '' };
    next();
  }, require('../src/video-resources').createVideoResourceRouter(resources));
  server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  await store?.close();
  await pool.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
  await pool.end();
});

test('管理员新增视频资源，普通成员只读启用项，单位之间相互隔离', async () => {
  const denied = await request('/api/video-resources', {
    member: 'reader',
    method: 'POST',
    body: { name: '越权资源', streamUrl: 'https://video.example.test/one.flv' },
  });
  assert.equal(denied.status, 403);

  const createdResponse = await request('/api/video-resources', {
    member: 'manager',
    method: 'POST',
    body: {
      name: '合成一号监控',
      description: '仅用于自动化测试',
      streamUrl: 'https://video.example.test/one.flv',
    },
  });
  assert.equal(createdResponse.status, 201);
  const created = await createdResponse.json();
  assert.equal(created.unit_id, 'one');
  assert.equal(created.active, true);

  const readerList = await request('/api/video-resources', { member: 'reader' });
  assert.equal(readerList.status, 200);
  const readers = await readerList.json();
  assert.deepEqual(readers.resources.map((item) => item.name), ['合成一号监控']);
  assert.deepEqual(
    (await (await request('/api/video-resources', { member: 'other' })).json()).resources,
    [],
  );

  const updatedResponse = await request(`/api/video-resources/${created.id}`, {
    member: 'manager',
    method: 'PATCH',
    body: {
      active: false,
      expected_version: created.version,
    },
  });
  assert.equal(updatedResponse.status, 200);
  assert.equal((await updatedResponse.json()).active, false);
  assert.deepEqual(
    (await (await request('/api/video-resources', { member: 'reader' })).json()).resources,
    [],
  );
  const managed = await request(
    '/api/video-resources?include_inactive=1',
    { member: 'manager' },
  );
  assert.equal((await managed.json()).resources.length, 1);
});

test('地址校验、并发版本与权限访问结果一致', async () => {
  const invalid = await request('/api/video-resources', {
    member: 'manager',
    method: 'POST',
    body: { name: '不安全地址', streamUrl: 'javascript:alert(1)' },
  });
  assert.equal(invalid.status, 400);
  assert.equal((await invalid.json()).code, 'VIDEO_RESOURCE_INVALID');

  const created = await (await request('/api/video-resources', {
    member: 'manager',
    method: 'POST',
    body: { name: '合成二号监控', streamUrl: 'https://video.example.test/two.flv' },
  })).json();
  const conflict = await request(`/api/video-resources/${created.id}`, {
    member: 'manager',
    method: 'PATCH',
    body: { name: '过期修改', expected_version: created.version - 1 },
  });
  assert.equal(conflict.status, 409);
  assert.equal((await conflict.json()).code, 'VIDEO_RESOURCE_CONFLICT');

  assert.deepEqual(
    await (await request('/api/video-resources/access', { member: 'reader' })).json(),
    { can_manage: false },
  );
  assert.deepEqual(
    await (await request('/api/video-resources/access', { member: 'manager' })).json(),
    { can_manage: true },
  );
});
