const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('child_process');
const fs = require('fs');
const http = require('http');
const net = require('net');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { DatabaseSync } = require('node:sqlite');

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

test('视频语音转写无会话时仍受认证保护', async () => {
  const response = await fetch(`${base}/api/media/transcribe`, {
    method: 'POST',
    headers: headers({ 'Content-Type': 'audio/wav' }),
    body: Buffer.alloc(44),
  });
  assert.equal(response.status, 401);
  assert.equal((await json(response)).code, 'SESSION_REQUIRED');
});

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

  response = await fetch(`${base}/api/hazmats`, { headers: headers() });
  assert.equal(response.status, 401);
  assert.equal((await json(response)).code, 'SESSION_REQUIRED');

  const sessionHeaders = headers({ Authorization: `Bearer ${memberAuth.session_token}` });
  response = await fetch(`${base}/api/auth/refresh`, { method: 'POST', headers: sessionHeaders });
  assert.equal(response.status, 200);
  const refreshedAuth = await json(response);
  assert.equal(refreshedAuth.refreshed, true);
  assert.equal(refreshedAuth.session_token, memberAuth.session_token);
  assert.ok(refreshedAuth.expires_at >= memberAuth.expires_at);
  assert.ok(refreshedAuth.absolute_expires_at > refreshedAuth.expires_at);

  response = await fetch(`${base}/api/config`, { headers: sessionHeaders });
  assert.equal(response.status, 200);
  assert.deepEqual((await json(response)).unit, { id: 'session-test-unit', name: '会话测试单位' });

  response = await fetch(`${base}/api/config`, {
    headers: headers({ Authorization: 'Bearer invalid-session', 'X-Unit-Id': 'session-test-unit', 'X-Unit-Code': '2468' }),
  });
  assert.equal(response.status, 401);
  assert.equal((await json(response)).code, 'SESSION_INVALID');

  response = await fetch(`${base}/api/auth/refresh`, {
    method: 'POST',
    headers: headers({ Authorization: 'Bearer invalid-session' }),
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
    body: JSON.stringify({ name: '成员可新增名单' }),
  });
  assert.equal(response.status, 201);

  response = await fetch(`${base}/api/hotwords`, {
    method: 'POST',
    headers: sessionHeaders,
    body: JSON.stringify({ word: '成员可新增词' }),
  });
  assert.equal(response.status, 201);

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

  response = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: headers({ 'X-Device-Id': 'session-expired-device' }),
    body: JSON.stringify({ unit_name: '会话测试单位', unit_code: '2468', real_name: '队员' }),
  });
  assert.equal(response.status, 200);
  const expiredAuth = await json(response);
  const sqlite = new DatabaseSync(path.join(dataDir, 'watchdog.db'));
  const expiredHash = crypto.createHash('sha256').update(expiredAuth.session_token).digest('hex');
  sqlite.prepare('UPDATE auth_sessions SET expires_at = ? WHERE token_hash = ?')
    .run(Date.now() - 1, expiredHash);
  response = await fetch(`${base}/api/auth/refresh`, {
    method: 'POST',
    headers: headers({ Authorization: `Bearer ${expiredAuth.session_token}` }),
  });
  assert.equal(response.status, 401);
  assert.equal((await json(response)).code, 'SESSION_EXPIRED');
  response = await fetch(`${base}/api/incidents`, {
    headers: headers({ Authorization: `Bearer ${expiredAuth.session_token}` }),
  });
  assert.equal(response.status, 401);
  assert.equal((await json(response)).code, 'SESSION_EXPIRED');

  response = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: headers({ 'X-Device-Id': 'session-absolute-expired-device' }),
    body: JSON.stringify({ unit_name: '会话测试单位', unit_code: '2468', real_name: '队员' }),
  });
  assert.equal(response.status, 200);
  const absoluteExpiredAuth = await json(response);
  const absoluteHash = crypto.createHash('sha256').update(absoluteExpiredAuth.session_token).digest('hex');
  sqlite.prepare('UPDATE auth_sessions SET created_at = ?, expires_at = ? WHERE token_hash = ?')
    .run(Date.now() - 31 * 24 * 60 * 60 * 1000, Date.now() + 60_000, absoluteHash);
  response = await fetch(`${base}/api/auth/refresh`, {
    method: 'POST',
    headers: headers({ Authorization: `Bearer ${absoluteExpiredAuth.session_token}` }),
  });
  assert.equal(response.status, 401);
  assert.equal((await json(response)).code, 'SESSION_EXPIRED');
  sqlite.close();
});

function allocateFreePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once('error', reject);
    probe.listen(0, '127.0.0.1', () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

async function waitAwayFromMinuteBoundary() {
  const remaining = 60000 - (Date.now() % 60000);
  if (remaining < 3000) {
    await new Promise((resolve) => setTimeout(resolve, remaining + 50));
  }
}

async function withAiRateLimitServer(limits, run) {
  await waitAwayFromMinuteBoundary();
  const mockLlm = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      let body = {};
      try { body = JSON.parse(raw || '{}'); } catch (_) {}
      const isVision = body?.text?.format?.type === 'json_object';
      const outputText = isVision
        ? JSON.stringify({
            relevance: 'related',
            category: 'fire_scene',
            summary: '模拟现场图片分析结果',
            findings: ['可见烟气'],
            hazards: [],
            suggestions: ['保持安全距离'],
            to_confirm: [],
          })
        : '先确认气瓶余量并保持安全距离';
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        output: [{ type: 'message', content: [{ type: 'output_text', text: outputText }] }],
      }));
    });
  });
  await new Promise((resolve) => mockLlm.listen(0, '127.0.0.1', resolve));
  const mockLlmBase = `http://127.0.0.1:${mockLlm.address().port}`;

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-ai-rl-'));
  const port = await allocateFreePort();
  const token = 'ai-rl-api-token';
  const proc = spawn(process.execPath, ['src/server.js'], {
    cwd: path.join(__dirname, '..'),
    env: {
      ...process.env,
      NODE_ENV: 'test',
      WATCHDOG_DB_DRIVER: 'sqlite',
      PORT: String(port),
      API_TOKEN: token,
      DEEPSEEK_API_KEY: 'test-deepseek-key',
      DEEPSEEK_BASE_URL: mockLlmBase,
      WATCHDOG_UNIT_AUTH_REQUIRED: '1',
      WATCHDOG_SESSION_AUTH_REQUIRED: '1',
      WATCHDOG_MEMBER_AUTH_REQUIRED: '1',
      WATCHDOG_SEED_UNIT_ID: 'rl-test-unit',
      WATCHDOG_SEED_UNIT_NAME: '示例大队',
      WATCHDOG_SEED_UNIT_CODE: '1001',
      WATCHDOG_SEED_UNIT_MEMBERS: '[{"real_name":"张三","role":"member"},{"real_name":"李四","role":"member"},{"real_name":"王五","role":"member"}]',
      WATCHDOG_DATA_DIR: tmpDir,
      CHAT_MEMBER_RATE_LIMIT: String(limits.chatMember ?? 10),
      CHAT_UNIT_RATE_LIMIT: String(limits.chatUnit ?? 60),
      VISION_MEMBER_RATE_LIMIT: String(limits.visionMember ?? 3),
      VISION_UNIT_RATE_LIMIT: String(limits.visionUnit ?? 20),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stderr = '';
  proc.stderr.on('data', (chunk) => { stderr += chunk.toString(); });

  try {
    const serverBase = `http://127.0.0.1:${port}`;
    let ready = false;
    for (let i = 0; i < 80; i++) {
      try {
        const res = await fetch(`${serverBase}/api/health`);
        if (res.status === 200) {
          ready = true;
          break;
        }
      } catch (_) {}
      if (proc.exitCode != null) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    if (!ready) throw new Error(`AI 限流测试服务未启动: ${stderr}`);

    async function login(realName, deviceId) {
      const res = await fetch(`${serverBase}/api/auth/verify`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Api-Token': token,
          'X-Device-Id': deviceId,
        },
        body: JSON.stringify({ unit_name: '示例大队', unit_code: '1001', real_name: realName }),
      });
      assert.equal(res.status, 200);
      const data = await res.json();
      return data.session_token;
    }

    async function postChat(sessionToken, message, ip = '203.0.113.10') {
      return fetch(`${serverBase}/api/chat`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Api-Token': token,
          Authorization: `Bearer ${sessionToken}`,
          'X-Forwarded-For': ip,
        },
        body: JSON.stringify({ message }),
      });
    }

    async function postVision(sessionToken, ip = '203.0.113.10') {
      const form = new FormData();
      form.append('message', '识别现场风险');
      form.append('image', new Blob([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])], { type: 'image/png' }), 'scene.png');
      return fetch(`${serverBase}/api/chat/vision`, {
        method: 'POST',
        headers: {
          'X-Api-Token': token,
          Authorization: `Bearer ${sessionToken}`,
          'X-Forwarded-For': ip,
        },
        body: form,
      });
    }

    await run({ serverBase, login, postChat, postVision });
  } finally {
    if (proc.exitCode == null) {
      proc.kill('SIGTERM');
      await new Promise((resolve) => proc.once('exit', resolve));
    }
    await new Promise((resolve) => mockLlm.close(resolve));
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

test('POST /api/chat 双层限流：同 IP 多成员互不误伤', async () => {
  await withAiRateLimitServer({ chatMember: 2, chatUnit: 10 }, async ({ login, postChat }) => {
    const tokenA = await login('张三', 'dev-a');
    const tokenB = await login('李四', 'dev-b');
    const sharedIp = '198.51.100.77';

    assert.equal((await postChat(tokenA, '烟气太大怎么处理', sharedIp)).status, 200);
    assert.equal((await postChat(tokenA, '气瓶余压警戒线是多少', sharedIp)).status, 200);
    const blockedA = await postChat(tokenA, '第三次提问', sharedIp);
    assert.equal(blockedA.status, 429);
    assert.equal((await blockedA.json()).code, 'CHAT_MEMBER_RATE_LIMITED');

    // 同出口 IP 下的另一位成员李四不受张三限流影响
    assert.equal((await postChat(tokenB, '浓烟内攻注意什么', sharedIp)).status, 200);
    assert.equal((await postChat(tokenB, '紧急撤离信号是什么', sharedIp)).status, 200);
  });
});

test('POST /api/chat 双层限流：单成员轮换 IP 无法绕过个人限流', async () => {
  await withAiRateLimitServer({ chatMember: 2, chatUnit: 10 }, async ({ login, postChat }) => {
    const tokenA = await login('张三', 'dev-rotate');

    assert.equal((await postChat(tokenA, '提问一', '198.51.100.1')).status, 200);
    assert.equal((await postChat(tokenA, '提问二', '198.51.100.2')).status, 200);
    const blocked = await postChat(tokenA, '换 IP 提问三', '198.51.100.3');
    assert.equal(blocked.status, 429);
    assert.equal((await blocked.json()).code, 'CHAT_MEMBER_RATE_LIMITED');
    const retryAfter = Number(blocked.headers.get('retry-after'));
    assert.ok(Number.isInteger(retryAfter) && retryAfter >= 1 && retryAfter <= 60);
  });
});

test('POST /api/chat 双层限流：单位总量上限封顶生效', async () => {
  await withAiRateLimitServer({ chatMember: 2, chatUnit: 3 }, async ({ login, postChat }) => {
    const tokenA = await login('张三', 'dev-u1');
    const tokenB = await login('李四', 'dev-u2');

    assert.equal((await postChat(tokenA, '问题1', '198.51.100.11')).status, 200);
    assert.equal((await postChat(tokenA, '问题2', '198.51.100.11')).status, 200);
    assert.equal((await postChat(tokenB, '问题3', '198.51.100.12')).status, 200);

    // 李四个人还有额度（仅用 1/2），但单位总量已达 3/3，应返回单位级 429
    const unitBlocked = await postChat(tokenB, '问题4', '198.51.100.12');
    assert.equal(unitBlocked.status, 429);
    assert.equal((await unitBlocked.json()).code, 'CHAT_UNIT_RATE_LIMITED');
    const retryAfter = Number(unitBlocked.headers.get('retry-after'));
    assert.ok(Number.isInteger(retryAfter) && retryAfter >= 1 && retryAfter <= 60);
  });
});

test('POST /api/chat 双层限流：个人超限请求绝不消耗单位配额', async () => {
  await withAiRateLimitServer({ chatMember: 1, chatUnit: 2 }, async ({ login, postChat }) => {
    const tokenA = await login('张三', 'dev-spam');
    const tokenB = await login('李四', 'dev-normal');

    assert.equal((await postChat(tokenA, '正常提问', '198.51.100.21')).status, 200);
    // 张三连续刷 5 次超限请求，全部在个人层拦截，绝不扣减单位总量
    for (let i = 0; i < 5; i++) {
      const blocked = await postChat(tokenA, `刷量提问${i}`, '198.51.100.21');
      assert.equal(blocked.status, 429);
      assert.equal((await blocked.json()).code, 'CHAT_MEMBER_RATE_LIMITED');
    }
    // 单位总量只消耗了 1/2，李四仍可正常成功提问
    assert.equal((await postChat(tokenB, '李四正常提问', '198.51.100.22')).status, 200);
  });
});

test('POST /api/chat/vision 双层限流：成员限流不耗单位额度且单位总量封顶', async () => {
  await withAiRateLimitServer({ visionMember: 1, visionUnit: 2 }, async ({ login, postVision }) => {
    const tokenA = await login('张三', 'dev-v1');
    const tokenB = await login('李四', 'dev-v2');
    const tokenC = await login('王五', 'dev-v3');

    assert.equal((await postVision(tokenA, '198.51.100.31')).status, 200);
    // 张三超限触发成员层 429，且不消耗单位配额（即使换 IP 也不能绕过）
    const memberBlocked = await postVision(tokenA, '198.51.100.39');
    assert.equal(memberBlocked.status, 429);
    assert.equal((await memberBlocked.json()).code, 'VISION_MEMBER_RATE_LIMITED');
    const memberRetry = Number(memberBlocked.headers.get('retry-after'));
    assert.ok(Number.isInteger(memberRetry) && memberRetry >= 1 && memberRetry <= 60);

    // 李四使用单位第 2 个名额仍可成功
    assert.equal((await postVision(tokenB, '198.51.100.32')).status, 200);

    // 王五未超个人限额，但触发单位总量封顶 429
    const unitBlocked = await postVision(tokenC, '198.51.100.33');
    assert.equal(unitBlocked.status, 429);
    assert.equal((await unitBlocked.json()).code, 'VISION_UNIT_RATE_LIMITED');
    const unitRetry = Number(unitBlocked.headers.get('retry-after'));
    assert.ok(Number.isInteger(unitRetry) && unitRetry >= 1 && unitRetry <= 60);
  });
});
