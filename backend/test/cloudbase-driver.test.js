const { test } = require('node:test');
const assert = require('node:assert/strict');
const { CloudBasePostgrestClient } = require('../src/cloudbase-postgrest');

test('CloudBase PostgREST 客户端发送 service_role 鉴权和查询参数', async () => {
  const calls = [];
  const client = new CloudBasePostgrestClient({
    envId: 'pg-test-env',
    apiKey: 'service-role-test-key',
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), options });
      return new Response(JSON.stringify([{ id: 'row-1', scene: 'scene-a' }]), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    },
  });

  const rows = await client.select('entries', {
    filters: { scene: 'scene-a', exited_at: { op: 'is', value: 'null' } },
    order: 'entry_at.desc',
    limit: 10,
  });

  assert.deepEqual(rows, [{ id: 'row-1', scene: 'scene-a' }]);
  assert.equal(calls.length, 1);
  const requestUrl = new URL(calls[0].url);
  assert.equal(requestUrl.pathname, '/v1/rdb/rest/entries');
  assert.equal(requestUrl.searchParams.get('scene'), 'eq.scene-a');
  assert.equal(requestUrl.searchParams.get('exited_at'), 'is.null');
  assert.equal(requestUrl.searchParams.get('order'), 'entry_at.desc');
  assert.equal(requestUrl.searchParams.get('limit'), '10');
  assert.equal(calls[0].options.headers.Authorization, 'Bearer service-role-test-key');
  assert.equal(calls[0].options.headers['Content-Type'], undefined);
});

test('CloudBase PostgREST 客户端支持插入返回值和重复键错误', async () => {
  const calls = [];
  const client = new CloudBasePostgrestClient({
    envId: 'pg-test-env',
    apiKey: 'service-role-test-key',
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), options });
      if (options.method === 'POST' && calls.length === 2) {
        return new Response(JSON.stringify({ message: 'duplicate key value violates unique constraint' }), { status: 409 });
      }
      return new Response(JSON.stringify([{ id: 'new-id' }]), { status: 201 });
    },
  });

  const inserted = await client.insert('firefighters', { id: 'new-id', name: '张三' }, { onConflict: 'name' });
  assert.deepEqual(inserted, [{ id: 'new-id' }]);
  assert.match(calls[0].options.headers.Prefer, /return=representation/);
  assert.equal(new URL(calls[0].url).searchParams.get('on_conflict'), 'name');

  await assert.rejects(
    () => client.insert('firefighters', { id: 'another-id', name: '张三' }),
    (error) => error.status === 409 && /UNIQUE constraint violation/.test(error.message),
  );
});

test('兼容 CloudBase 云托管选择 API Key 注入的变量名', () => {
  const previousApiKey = process.env.CLOUDBASE_API_KEY;
  const previousInjectedApiKey = process.env.CLOUDBASE_APIKEY;
  try {
    delete process.env.CLOUDBASE_API_KEY;
    process.env.CLOUDBASE_APIKEY = 'cloudbase-injected-key';
    const client = new CloudBasePostgrestClient({ envId: 'pg-test-env' });
    assert.equal(client.apiKey, 'cloudbase-injected-key');
  } finally {
    if (previousApiKey === undefined) delete process.env.CLOUDBASE_API_KEY;
    else process.env.CLOUDBASE_API_KEY = previousApiKey;
    if (previousInjectedApiKey === undefined) delete process.env.CLOUDBASE_APIKEY;
    else process.env.CLOUDBASE_APIKEY = previousInjectedApiKey;
  }
});
