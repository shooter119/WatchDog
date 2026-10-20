#!/usr/bin/env node
// Public, anonymous deployment checks. Never log QR credentials or Cookie values.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
const origin = process.env.WATCHDOG_PUBLIC_ORIGIN || 'https://fireman119.xyz';
const apiOrigin = process.env.WATCHDOG_PUBLIC_API || 'https://api.fireman119.xyz';
const checks = [];
const request = (base, path, options = {}) => fetch(new URL(path, base), { ...options, redirect: 'manual', signal: AbortSignal.timeout(15000) });
const digest = text => createHash('sha256').update(text).digest('hex');
async function check(name, run) { await run(); checks.push(name); }
const snapshotOnly = process.argv.includes('--snapshot');
const snapshot = {};
for (const [name, path] of [['website', '/'], ['ota', '/ota/latest.json']]) {
  const response = await request(origin, path); assert.equal(response.status, 200, `${name} unavailable`);
  snapshot[name] = digest(await response.text());
}
if (snapshotOnly) { console.log(JSON.stringify(snapshot)); process.exit(0); }
if (process.env.WATCHDOG_PRE_DEPLOY_SNAPSHOT) assert.deepEqual(snapshot, JSON.parse(process.env.WATCHDOG_PRE_DEPLOY_SNAPSHOT), 'website/OTA changed unexpectedly');
await check('website_and_ota_preserved', async () => {});
await check('backend_health', async () => { const response = await request(apiOrigin, '/api/health'); assert.equal(response.status, 200); assert.match(response.headers.get('content-type'), /json/); });
await check('admin_shell_and_security_headers', async () => {
  const response = await request(origin, '/admin/'); assert.equal(response.status, 200);
  assert.match(await response.text(), /火场智控 · 资料管理/);
  assert.match(response.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  assert.match(response.headers.get('cache-control'), /no-store/);
  for (const path of ['/admin/app.js', '/admin/sites.js', '/admin/style.css']) assert.equal((await request(origin, path)).status, 200);
});
await check('ordinary_app_token_cannot_authorize_admin', async () => {
  const response = await request(origin, '/api/admin/me', { headers: { Authorization: 'Bearer synthetic-invalid-app-session' } });
  assert.equal(response.status, 401); assert.equal((await response.json()).code, 'ADMIN_SESSION_INVALID');
});
await check('csrf_origin_boundary', async () => {
  for (const headers of [{}, { Origin: 'https://invalid.example' }]) {
    const response = await request(origin, '/api/admin/login/challenges', { method: 'POST', headers });
    assert.equal(response.status, 403); assert.equal((await response.json()).code, 'ADMIN_ORIGIN_INVALID');
  }
});
await check('qr_browser_binding_and_pending_state', async () => {
  const response = await request(origin, '/api/admin/login/challenges', { method: 'POST', headers: { Origin: origin } });
  assert.equal(response.status, 200);
  const cookies = response.headers.getSetCookie(); const browser = cookies.find(cookie => cookie.startsWith('__Host-watchdog_browser='));
  assert.ok(browser); for (const flag of ['Secure', 'HttpOnly', 'SameSite=Strict']) assert.ok(browser.includes(flag));
  const data = await response.json(); assert.ok(data.expiresAt > Date.now() && data.expiresAt <= Date.now() + 125000);
  assert.match(data.qrPayload, /^https:\/\/fireman119\.xyz\/admin\/scan#/); assert.match(data.qrImage, /^data:image\/png;base64,/);
  const claim = cookie => request(origin, '/api/admin/login/claim', { method: 'POST', headers: {
    Origin: origin, 'Content-Type': 'application/json', ...(cookie ? { Cookie: cookie } : {}),
  }, body: JSON.stringify({ id: data.id }) });
  assert.equal((await claim()).status, 409);
  const pending = await claim(browser.split(';')[0]); assert.equal(pending.status, 202);
  assert.deepEqual(await pending.json(), { state: 'pending' });
  assert.ok(!pending.headers.getSetCookie().some(cookie => cookie.startsWith('__Host-watchdog_admin=')));
});
await check('private_dossiers_and_legacy_maps_require_authentication', async () => {
  for (const path of ['/api/key-sites', '/api/key-sites/access', '/api/key-sites/guess/versions/1/attachments/guess/pages/1.jpg',
    '/api/key-sites/guess/versions/1/attachments/guess/maps/1/tiles/0/0/0.jpg', '/api/key-sites/guess/versions/1/attachments/guess/source', '/api/maps', '/api/admin-app/capability']) {
    const response = await request(apiOrigin, path); assert.equal(response.status, 401, `unguarded route ${path}`);
  }
});
console.log(JSON.stringify({ checks, snapshot, note: 'Anonymous public checks only; authorized phone QR and real-data pilot require separate evidence.' }, null, 2));
