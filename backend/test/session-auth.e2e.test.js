const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

let child;
let base;
let apiToken;
let dataDir;

before(async () => {
  dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-session-'));
  const port = 4300 + Math.floor(Math.random() * 400);
  apiToken = 'session-api-token';
  child = spawn(process.execPath, ['src/server.js'], {
    cwd: path.join(__dirname, '..'),
    env: {
      ...process.env,
      NODE_ENV: 'test',
      WATCHDOG_DB_DRIVER: 'sqlite',
      PORT: String(port),
      API_TOKEN: apiToken,
      WATCHDOG_UNIT_AUTH_REQUIRED: '1',
      WATCHDOG_SESSION_AUTH_REQUIRED: '1',
      WATCHDOG_MEMBER_AUTH_REQUIRED: '1',
      WATCHDOG_SEED_UNIT_ID: 'session-test-unit',
      WATCHDOG_SEED_UNIT_NAME: '会话测试单位',
      WATCHDOG_SEED_UNIT_CODE: '2468',
      WATCHDOG_SEED_UNIT_MEMBERS: '[{"real_name":"队员","role":"member"},{"real_name":"管理员","role":"manager"}]',
      WATCHDOG_DATA_DIR: dataDir,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
  for (let i = 0; i < 40; i++) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (response.status === 200) {
        base = `http://127.0.0.1:${port}`;
        return;
      }
    } catch (_) {}
    if (child.exitCode != null) break;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`会话认证测试服务未启动: ${stderr}`);
});

after(async () => {
  if (!child || child.exitCode != null) return;
  child.kill('SIGTERM');
  await new Promise((resolve) => child.once('exit', resolve));
});

function headers(extra = {}) {
  return { 'Content-Type': 'application/json', 'X-Api-Token': apiToken, ...extra };
}

async function json(response) {
  return response.json();
}

test('严格认证：成员白名单、会话绑定、注销和管理角色门禁', async () => {
  let response = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: headers({ 'X-Device-Id': 'session-member-device' }),
    body: JSON.stringify({ unit_name: '会话测试单位', unit_code: '2468', real_name: '未授权人员' }),
  });
  assert.equal(response.status, 403);
  assert.equal((await json(response)).code, 'MEMBER_NOT_ALLOWED');

  response = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: headers({ 'X-Device-Id': 'session-member-device' }),
    body: JSON.stringify({ unit_name: '会话测试单位', unit_code: '2468', real_name: '队员' }),
  });
  assert.equal(response.status, 200);
  const memberAuth = await json(response);
  assert.equal(memberAuth.user.role, 'member');
  assert.match(memberAuth.session_token, /^[A-Za-z0-9_-]{40,}$/);
  assert.ok(memberAuth.expires_at > Date.now());

  response = await fetch(`${base}/api/config`, { headers: headers() });
  assert.equal(response.status, 401);
  assert.equal((await json(response)).code, 'SESSION_REQUIRED');

  const sessionHeaders = headers({ Authorization: `Bearer ${memberAuth.session_token}` });
  response = await fetch(`${base}/api/config`, { headers: sessionHeaders });
  assert.equal(response.status, 200);
  assert.deepEqual((await json(response)).unit, { id: 'session-test-unit', name: '会话测试单位' });

  response = await fetch(`${base}/api/config`, {
    headers: headers({ Authorization: 'Bearer invalid-session', 'X-Unit-Id': 'session-test-unit', 'X-Unit-Code': '2468' }),
  });
  assert.equal(response.status, 401);
  assert.equal((await json(response)).code, 'SESSION_INVALID');

  response = await fetch(`${base}/api/incidents`, {
    method: 'POST',
    headers: { ...sessionHeaders, 'X-Actor-Name-B64': Buffer.from('伪造姓名').toString('base64') },
    body: JSON.stringify({ actor_name: '伪造姓名' }),
  });
  assert.equal(response.status, 201);
  const incident = await json(response);
  const createEvent = (await (await fetch(`${base}/api/incidents/${incident.id}/timeline`, { headers: sessionHeaders })).json()).events
    .find((event) => event.type === 'incident_created');
  assert.equal(createEvent.actor_name, '队员');

  response = await fetch(`${base}/api/notes`, {
    method: 'POST',
    headers: { ...sessionHeaders, 'X-Incident-Id': incident.id },
    body: JSON.stringify({ text: '现场记录', author: '伪造姓名' }),
  });
  assert.equal(response.status, 201);
  assert.equal((await json(response)).author, '队员');

  response = await fetch(`${base}/api/firefighters`, {
    method: 'POST',
    headers: sessionHeaders,
    body: JSON.stringify({ name: '成员不应修改名单' }),
  });
  assert.equal(response.status, 403);
  assert.equal((await json(response)).code, 'MANAGEMENT_REQUIRED');

  response = await fetch(`${base}/api/unit-members`, { headers: sessionHeaders });
  assert.equal(response.status, 403);
  assert.equal((await json(response)).code, 'MANAGEMENT_REQUIRED');

  response = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: headers({ 'X-Device-Id': 'session-manager-device' }),
    body: JSON.stringify({ unit_name: '会话测试单位', unit_code: '2468', real_name: '管理员' }),
  });
  assert.equal(response.status, 200);
  const managerAuth = await json(response);
  assert.equal(managerAuth.user.role, 'manager');
  const managerHeaders = headers({ Authorization: `Bearer ${managerAuth.session_token}` });
  response = await fetch(`${base}/api/firefighters`, {
    method: 'POST',
    headers: managerHeaders,
    body: JSON.stringify({ name: '管理员新增名单项' }),
  });
  assert.equal(response.status, 201);

  response = await fetch(`${base}/api/unit-members`, {
    method: 'POST',
    headers: managerHeaders,
    body: JSON.stringify({ real_name: '备勤人员', role: 'member' }),
  });
  assert.equal(response.status, 201);
  const standbyMember = await json(response);
  response = await fetch(`${base}/api/unit-members/${standbyMember.id}`, {
    method: 'PATCH',
    headers: managerHeaders,
    body: JSON.stringify({ status: 'disabled' }),
  });
  assert.equal(response.status, 200);

  response = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: headers({ 'X-Device-Id': 'session-disabled-device' }),
    body: JSON.stringify({ unit_name: '会话测试单位', unit_code: '2468', real_name: '备勤人员' }),
  });
  assert.equal(response.status, 403);

  response = await fetch(`${base}/api/auth/logout`, {
    method: 'POST',
    headers: { ...sessionHeaders, Authorization: `bEaReR ${memberAuth.session_token}` },
  });
  assert.equal(response.status, 200);
  response = await fetch(`${base}/api/config`, { headers: sessionHeaders });
  assert.equal(response.status, 401);
  assert.equal((await json(response)).code, 'SESSION_INVALID');
});
