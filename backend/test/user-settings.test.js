const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-usettings-'));
process.env.WATCHDOG_DATA_DIR = tmpDir;

const db = require('../src/db');
const app = require('../src/server');

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
  'X-Incident-Id': 'us-scene',
  'X-Device-Id': 'user-aaaa-1111',
};
const j = (r) => r.json();

test('db: saveUserSettings 按设备全局 upsert 并可读回', () => {
  const s1 = db.saveUserSettings('user-aaaa-1111', 'default', { warn_min: 12, tts_enabled: true });
  assert.equal(s1.settings.warn_min, 12);
  assert.equal(s1.settings.tts_enabled, true);
  assert.ok(s1.updatedAt > 0);

  // 覆盖已有键 + 新增键，updatedAt 更新
  const s2 = db.saveUserSettings('user-aaaa-1111', 'default', { warn_min: 15 });
  assert.equal(s2.settings.warn_min, 15);
  assert.equal(s2.settings.tts_enabled, true);
  assert.ok(s2.updatedAt >= s1.updatedAt);

  // 用户隔离：另一用户读不到
  const other = db.getUserSettings('user-bbbb-2222', 'us-scene');
  assert.deepEqual(other.settings, {});
  assert.equal(other.updatedAt, 0);

  // 设备设置不再按警情隔离，任意警情都使用同一份设备配置。
  const sameDevice = db.getUserSettings('user-aaaa-1111', 'default');
  assert.equal(sameDevice.settings.warn_min, 15);
});

test('GET /api/user-settings 缺 X-Device-Id 返回 400', async () => {
  const res = await fetch(`${base}/api/user-settings`, {
    headers: { 'Content-Type': 'application/json', 'X-Incident-Id': 'us-scene' },
  });
  assert.equal(res.status, 400);
});

test('GET /api/user-settings 无记录返回空设置', async () => {
  const res = await fetch(`${base}/api/user-settings`, {
    headers: { ...H, 'X-Device-Id': 'user-fresh-0000' },
  });
  assert.equal(res.status, 200);
  const body = await j(res);
  assert.deepEqual(body.settings, {});
  assert.equal(body.updated_at, 0);
});

test('PUT → GET 全链路：白名单过滤 + 类型校验 + 设备隔离', async () => {
  // 上传含非法键与非法类型
  const put = await fetch(`${base}/api/user-settings`, {
    method: 'PUT',
    headers: H,
    body: JSON.stringify({
      settings: {
        cylinder_vol_l: 9.5,
        warn_min: 12,
        tts_enabled: false,
        hack_key: 'nope',
        consumption_lpm: 'fast',
      },
    }),
  });
  assert.equal(put.status, 200);
  const putBody = await j(put);
  assert.deepEqual(putBody.settings, { cylinder_vol_l: 9.5, warn_min: 12, tts_enabled: false });
  assert.ok(putBody.updated_at > 0);

  const get = await j(await fetch(`${base}/api/user-settings`, { headers: H }));
  assert.deepEqual(get.settings, { cylinder_vol_l: 9.5, warn_min: 12, tts_enabled: false });
  assert.equal(get.updated_at, putBody.updated_at);

  // 无合法键拒绝
  const bad = await fetch(`${base}/api/user-settings`, {
    method: 'PUT',
    headers: H,
    body: JSON.stringify({ settings: { junk: 1 } }),
  });
  assert.equal(bad.status, 400);

  // 用户隔离：同场景不同用户互不可见
  const otherUser = await j(
    await fetch(`${base}/api/user-settings`, {
      headers: { ...H, 'X-Device-Id': 'user-bbbb-2222' },
    })
  );
  assert.deepEqual(otherUser.settings, {});
});

test('PUT 覆盖后旧值被替换', async () => {
  await fetch(`${base}/api/user-settings`, {
    method: 'PUT',
    headers: H,
    body: JSON.stringify({ settings: { warn_min: 20, alarm_min: 7 } }),
  });
  const body = await j(await fetch(`${base}/api/user-settings`, { headers: H }));
  assert.equal(body.settings.warn_min, 20);
  assert.equal(body.settings.alarm_min, 7);
  assert.equal(body.settings.cylinder_vol_l, 9.5);
});

test('real_name 实名同步：PUT 保存（trim）→ GET 读回 → 清空为匿名', async () => {
  // PUT 实名（带空格 trim 后保存）
  let res = await fetch(`${base}/api/user-settings`, {
    method: 'PUT',
    headers: H,
    body: JSON.stringify({ settings: { real_name: ' 张三 ' } }),
  });
  assert.equal(res.status, 200);
  let body = await j(res);
  assert.equal(body.settings.real_name, '张三');

  // GET 读回
  res = await fetch(`${base}/api/user-settings`, { headers: H });
  body = await j(res);
  assert.equal(body.settings.real_name, '张三');

  // 白名单外字符串键仍被拒绝
  res = await fetch(`${base}/api/user-settings`, {
    method: 'PUT',
    headers: H,
    body: JSON.stringify({ settings: { foo: 'bar' } }),
  });
  assert.equal(res.status, 400);

  // 清空实名 = 匿名
  res = await fetch(`${base}/api/user-settings`, {
    method: 'PUT',
    headers: H,
    body: JSON.stringify({ settings: { real_name: '' } }),
  });
  assert.equal(res.status, 200);
  body = await j(res);
  assert.equal(body.settings.real_name, '');
});
