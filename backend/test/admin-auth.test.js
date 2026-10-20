const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { Pool } = require('pg');
process.env.WATCHDOG_DB_DRIVER = 'postgres';
process.env.WATCHDOG_SKIP_SEED = '1';
const baseUrl = process.env.DATABASE_URL || 'postgresql:///watchdog_test';
const pool = new Pool({ connectionString: baseUrl });
const schema = `admin_auth_${process.pid}_${Date.now()}`;
let store, auth, server, base, time = Date.now();
before(async () => {
  await pool.query(`CREATE SCHEMA "${schema}"`);
  const url = new URL(baseUrl);
  url.searchParams.set('options', `-c search_path=${schema}`);
  process.env.DATABASE_URL = url.toString();
  store = require('../src/postgres-store');
  await store.ready;
  auth = require('../src/admin-auth').createAdminAuth(store, () => time);
  await store.query("INSERT INTO units(id,name,verification_code,created_at,updated_at) VALUES('u','测试单位','test',1,1)");
  for (const [id, role] of [['platform','member'],['manager','manager'],['ordinary','member'],['other','admin']]) {
    await store.query("INSERT INTO unit_members(id,unit_id,real_name,role,created_at,updated_at) VALUES($1,'u',$1,$2,1,1)", [id, role]);
  }
  await auth.setGrant(null, 'platform', 'platform_admin', { bootstrap: true });
  const app = require('express')();
  app.use(require('express').json());
  app.use('/api/admin', require('../src/admin-router').createAdminRouter(auth));
  server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}/api/admin`;
});
after(async () => {
  if (server) await new Promise(resolve => server.close(resolve));
  await store?.close();
  await pool.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
  await pool.end();
});
const rejects = (fn, code) => assert.rejects(fn, { code });

test('后台权限独立于单位角色，禁止普通成员和未授权管理员确认', async () => {
  const challenge = await auth.challenge();
  await rejects(() => auth.confirm(challenge.id, challenge.scan, 'ordinary'), 'ADMIN_FORBIDDEN');
  await rejects(() => auth.confirm(challenge.id, challenge.scan, 'other'), 'ADMIN_FORBIDDEN');
  await rejects(() => auth.setGrant('ordinary', 'ordinary', 'platform_admin'), 'ADMIN_FORBIDDEN');
  await auth.setGrant('platform', 'manager', 'unit_admin');
  await rejects(() => auth.setGrant('manager', 'other', 'unit_admin'), 'ADMIN_FORBIDDEN');
});

test('扫码前、跨浏览器、错误扫码凭据、复用均不能领取会话', async () => {
  const c = await auth.challenge();
  assert.equal(await auth.claim(c.id, c.browser), null);
  await rejects(() => auth.confirm(c.id, 'wrong', 'platform'), 'ADMIN_CHALLENGE_INVALID');
  await auth.confirm(c.id, c.scan, 'platform');
  await rejects(() => auth.claim(c.id, 'another-browser'), 'ADMIN_CHALLENGE_INVALID');
  const result = await auth.claim(c.id, c.browser);
  assert.equal(result.member.id, 'platform');
  await rejects(() => auth.claim(c.id, c.browser), 'ADMIN_CHALLENGE_INVALID');
  await rejects(() => auth.confirm(c.id, c.scan, 'platform'), 'ADMIN_CHALLENGE_INVALID');
  await rejects(() => auth.session(result.token, 'wrong', true), 'ADMIN_CSRF_INVALID');
  assert.equal((await auth.session(result.token, result.csrf, true)).id, 'platform');
});

test('取消和超过两分钟的二维码不能领取', async () => {
  const c = await auth.challenge();
  await auth.confirm(c.id, c.scan, 'platform', true);
  await rejects(() => auth.claim(c.id, c.browser), 'ADMIN_CHALLENGE_INVALID');
  const expired = await auth.challenge();
  time += 120000;
  await rejects(() => auth.confirm(expired.id, expired.scan, 'platform'), 'ADMIN_CHALLENGE_INVALID');
  await rejects(() => auth.claim(expired.id, expired.browser), 'ADMIN_CHALLENGE_INVALID');
});

test('并发领取只能成功一次，后台轮询不延长空闲会话', async () => {
  const c = await auth.challenge();
  await auth.confirm(c.id, c.scan, 'platform');
  const results = await Promise.allSettled([auth.claim(c.id, c.browser), auth.claim(c.id, c.browser)]);
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
  const session = results.find(result => result.status === 'fulfilled').value;
  time += 29 * 60000;
  await auth.session(session.token, undefined, false, false);
  time += 60000;
  await rejects(() => auth.session(session.token), 'ADMIN_SESSION_INVALID');
});

async function login(member = 'platform') {
  const c = await auth.challenge();
  await auth.confirm(c.id, c.scan, member);
  return auth.claim(c.id, c.browser);
}

test('撤权、管理角色变化、停用和退出即时拒绝后续会话', async () => {
  await auth.setGrant('platform', 'manager', 'unit_admin');
  const revoked = await login('manager');
  await auth.setGrant('platform', 'manager', null);
  await rejects(() => auth.session(revoked.token), 'ADMIN_SESSION_INVALID');
  await auth.setGrant('platform', 'manager', 'unit_admin');
  const changed = await login('manager');
  await store.query("UPDATE unit_members SET role='member' WHERE id='manager'");
  await rejects(() => auth.session(changed.token), 'ADMIN_SESSION_INVALID');
  await store.query("UPDATE unit_members SET role='manager' WHERE id='manager'");
  await rejects(() => auth.session(changed.token), 'ADMIN_SESSION_INVALID');
  const disabled = await login('manager');
  await store.query("UPDATE unit_members SET status='disabled' WHERE id='manager'");
  await store.query("UPDATE unit_members SET status='active' WHERE id='manager'");
  await rejects(() => auth.session(disabled.token), 'ADMIN_SESSION_INVALID');
  const loggedOut = await login();
  await auth.logout(loggedOut.token, true);
  await rejects(() => auth.session(loggedOut.token), 'ADMIN_SESSION_INVALID');
});

test('空闲30分钟和绝对8小时均使会话过期', async () => {
  const idle = await login();
  time += 30 * 60000;
  await rejects(() => auth.session(idle.token), 'ADMIN_SESSION_INVALID');
  const absolute = await login();
  for (let i = 0; i < 16; i++) {
    time += 29 * 60000;
    await auth.session(absolute.token);
  }
  time += 16 * 60000;
  await rejects(() => auth.session(absolute.token), 'ADMIN_SESSION_INVALID');
});

test('保护最后有效平台管理员，私有初始化不可重复，审计不含凭据', async () => {
  await rejects(() => auth.setGrant('platform', 'platform', null), 'ADMIN_LAST_PLATFORM');
  await rejects(() => auth.setGrant(null, 'other', 'platform_admin', { bootstrap: true }), 'ADMIN_ALREADY_INITIALIZED');
  const rows = (await store.query('SELECT * FROM admin_audit')).rows;
  assert.ok(rows.some(row => row.action === 'login'));
  assert.ok(rows.every(row => Object.keys(row).sort().join(',') === 'action,actor_id,created_at,id,target_id'));
});

test('HTTP 独立Cookie、来源限制、CSRF与已有会话恢复', async () => {
  const request = (path, body, headers = {}, method = 'POST') => fetch(base + path, {
    method, headers: { Origin: 'https://fireman119.xyz', 'Content-Type': 'application/json', ...headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  assert.equal((await request('/me', undefined, { Authorization: 'Bearer app-token' }, 'GET')).status, 401);
  assert.equal((await request('/login/challenges', {}, { Origin: 'https://attacker.example' })).status, 403);
  const response = await request('/login/challenges', {});
  const browserCookie = response.headers.get('set-cookie');
  assert.match(browserCookie, /Secure/); assert.match(browserCookie, /HttpOnly/); assert.match(browserCookie, /SameSite=Strict/);
  const c = await response.json();
  assert.match(c.qrImage, /^data:image\/png;base64,/);
  assert.equal(c.browser, undefined);
  const scan = c.qrPayload.split('.').at(-1);
  await auth.confirm(c.id, scan, 'platform');
  assert.equal((await request('/login/claim', { id: c.id })).status, 409);
  const claimed = await request('/login/claim', { id: c.id }, { Cookie: browserCookie.split(';')[0] });
  assert.equal(claimed.status, 200);
  const sessionCookie = claimed.headers.getSetCookie().find(value => value.startsWith('__Host-watchdog_admin=')).split(';')[0];
  const result = await claimed.json();
  assert.equal(result.token, undefined);
  const restored = await request('/me', undefined, { Cookie: sessionCookie }, 'GET');
  assert.equal((await restored.json()).csrf, result.csrf);
  assert.equal((await request('/logout', {}, { Cookie: sessionCookie })).status, 403);
  assert.equal((await request('/logout', {}, { Cookie: sessionCookie, 'X-CSRF-Token': result.csrf })).status, 200);
  assert.equal((await request('/me', undefined, { Cookie: sessionCookie }, 'GET')).status, 401);
});

test('授权变更与实时通知同事务提交，通知失败回滚权限，事件不含登录凭据', async () => {
  const db = require('../src/db-postgres');
  await store.query("INSERT INTO unit_members(id,unit_id,real_name,role,created_at,updated_at) VALUES('event-member','u','合成成员','manager',1,1)");
  const eventAuth = require('../src/admin-auth').createAdminAuth(store, () => time, {
    onGrantChanged: member => db.appendRosterSyncEvent({ unitId: member.unit_id, eventType: 'admin.capability_changed',
      aggregateId: member.id, payload: { memberId: member.id } }),
  });
  await eventAuth.setGrant('platform', 'event-member', 'unit_admin');
  assert.equal((await eventAuth.identity('event-member')).admin_role, 'unit_admin');
  const events = (await store.query("SELECT * FROM sync_events WHERE event_type='admin.capability_changed'")).rows;
  assert.equal(events.length, 1); assert.deepEqual(events[0].payload, { memberId: 'event-member' });
  const failing = require('../src/admin-auth').createAdminAuth(store, () => time, { onGrantChanged: () => { throw new Error('synthetic outbox failure'); } });
  await assert.rejects(() => failing.setGrant('platform', 'event-member', null));
  assert.ok(await eventAuth.identity('event-member'));
  await eventAuth.setGrant('platform', 'event-member', null);
  assert.equal(await eventAuth.identity('event-member'), undefined);
  assert.equal((await store.query("SELECT count(*)::int AS n FROM sync_events WHERE event_type='admin.capability_changed'")).rows[0].n, 2);
});
