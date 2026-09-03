const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const WebSocket = require('ws');

process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgresql:///watchdog_test';
const store = require('../src/postgres-store');

const unitId = `realtime-unit-${randomUUID()}`;
const incidentId = `realtime-incident-${randomUUID()}`;
const code = `rt-code-${randomUUID()}`;
const ports = [4600 + Math.floor(Math.random() * 200), 4800 + Math.floor(Math.random() * 200)];
const children = [];
let baseA;
let baseB;

function headers(device = 'realtime-test-device') {
  return {
    'Content-Type': 'application/json',
    'X-Unit-Id': unitId,
    'X-Unit-Code': code,
    'X-Device-Id': device,
    'X-Incident-Id': incidentId,
  };
}

async function waitForHealth(child, port) {
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
  for (let i = 0; i < 60; i += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (response.status === 200) return;
    } catch (_) {}
    if (child.exitCode != null) break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`实时测试服务未启动: ${stderr}`);
}

function startServer(port) {
  const child = spawn(process.execPath, ['src/server.js'], {
    cwd: require('node:path').join(__dirname, '..'),
    env: {
      ...process.env,
      NODE_ENV: 'development',
      WATCHDOG_DB_DRIVER: 'postgres',
      WATCHDOG_SKIP_SEED: '1',
      DATABASE_URL: process.env.DATABASE_URL,
      WATCHDOG_UNIT_AUTH_REQUIRED: '1',
      WATCHDOG_SESSION_AUTH_REQUIRED: '0',
      WATCHDOG_MEMBER_AUTH_REQUIRED: '0',
      WATCHDOG_METRICS_TOKEN: 'realtime-metrics-token',
      PORT: String(port),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  children.push(child);
  return child;
}

function openSyncSocket(device = 'realtime-test-device') {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(`ws://127.0.0.1:${ports[0]}/api/realtime`, {
      headers: headers(device),
    });
    const messages = [];
    socket.on('message', (data) => {
      try { messages.push(JSON.parse(data.toString())); } catch (_) {}
    });
    socket.once('open', () => {
      socket.send(JSON.stringify({
        type: 'subscribe',
        unit_cursor: '0',
        incident_cursor: '0',
        incident_id: incidentId,
      }));
      resolve({ socket, messages });
    });
    socket.once('error', reject);
  });
}

function waitForMessage(messages, predicate) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 3000;
    const timer = setInterval(() => {
      const found = messages.find(predicate);
      if (found) {
        clearInterval(timer);
        resolve(found);
      } else if (Date.now() >= deadline) {
        clearInterval(timer);
        reject(new Error('等待实时消息超时'));
      }
    }, 10);
  });
}

before(async () => {
  await store.ready;
  const now = Date.now();
  await store.query(
    'INSERT INTO units (id, name, verification_code, created_at, updated_at) VALUES ($1,$2,$3,$4,$4)',
    [unitId, unitId, code, now],
  );
  await store.query(
    'INSERT INTO incidents (id, unit_id, number, title, status, created_at, last_activity_at, version) VALUES ($1,$2,$3,$4,$5,$6,$6,1)',
    [incidentId, unitId, `实时-${randomUUID()}`, '实时协议测试', 'active', now],
  );
  const first = startServer(ports[0]);
  const second = startServer(ports[1]);
  await Promise.all([waitForHealth(first, ports[0]), waitForHealth(second, ports[1])]);
  baseA = `http://127.0.0.1:${ports[0]}`;
  baseB = `http://127.0.0.1:${ports[1]}`;
});

after(async () => {
  for (const child of children) {
    if (child.exitCode == null) child.kill('SIGTERM');
  }
  await Promise.all(children.map((child) => new Promise((resolve) => {
    if (child.exitCode != null) return resolve();
    child.once('exit', resolve);
  })));
  await store.query('DELETE FROM operation_ledger WHERE unit_id = $1', [unitId]);
  await store.query('DELETE FROM incident_events WHERE incident_id = $1', [incidentId]);
  await store.query('DELETE FROM sync_events WHERE unit_id = $1', [unitId]);
  await store.query('DELETE FROM sync_streams WHERE stream_key IN ($1, $2)', [`unit:${unitId}`, `incident:${incidentId}`]);
  await store.query('DELETE FROM incidents WHERE id = $1', [incidentId]);
  await store.query('DELETE FROM units WHERE id = $1', [unitId]);
  await store.close();
});

test('bootstrap 返回单位词库、活动警情和十进制游标', { concurrency: false }, async () => {
  const response = await fetch(`${baseA}/api/sync/bootstrap?incident_id=${incidentId}`, { headers: headers() });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.unit.id, unitId);
  assert.equal(body.incident_snapshot.incident.id, incidentId);
  assert.match(body.cursors.unit, /^\d+$/);
  assert.match(body.cursors.incident, /^\d+$/);
  assert.ok(Array.isArray(body.roster.firefighters));
  assert.ok(Array.isArray(body.roster.hotwords));
});

test('实例 B 写入后，实例 A 的 WebSocket 在同一单位收到警情事件', { concurrency: false }, async () => {
  const connected = await openSyncSocket();
  await waitForMessage(connected.messages, (message) => message.type === 'ready');
  const opId = `rt-${randomUUID()}`;
  const response = await fetch(`${baseB}/api/notes`, {
    method: 'POST',
    headers: {
      ...headers('writer-device'),
      'X-Actor-Name-B64': Buffer.from('测试员').toString('base64'),
      'X-Op-Id': opId,
    },
    body: JSON.stringify({ text: '跨实例实时事件', category: '其他' }),
  });
  assert.equal(response.status, 201);
  const written = await response.json();
  assert.equal(typeof written.event_id, 'string');
  assert.match(written.stream_sequence, /^\d+$/);
  const event = await waitForMessage(connected.messages, (message) => message.event_type === 'note.created' && message.client_op_id === opId);
  assert.equal(event.type, 'event');
  assert.equal(event.stream, 'incident');
  assert.equal(event.payload.text, '跨实例实时事件');
  connected.socket.close();
});

test('事件补拉按游标返回连续事件并隔离单位', { concurrency: false }, async () => {
  const response = await fetch(`${baseA}/api/sync/events?incident_id=${incidentId}&unit_cursor=0&incident_cursor=0`, { headers: headers() });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.ok(body.events.some((event) => event.event_type === 'note.created'));
  for (const event of body.events) {
    assert.equal(event.unit_id, unitId);
    assert.match(event.sequence, /^\d+$/);
  }
});

test('同一设备的新 WebSocket 会替换旧连接', { concurrency: false }, async () => {
  const first = await openSyncSocket('replacement-device');
  await waitForMessage(first.messages, (message) => message.type === 'ready');
  const oldConnectionClosed = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('旧实时连接未被替换')), 2000);
    first.socket.once('close', () => { clearTimeout(timer); resolve(); });
  });
  const second = await openSyncSocket('replacement-device');
  await waitForMessage(second.messages, (message) => message.type === 'ready');
  const metrics = await (await fetch(`${baseA}/api/metrics`, { headers: { 'X-Metrics-Token': 'realtime-metrics-token' } })).json();
  assert.ok(metrics.websocket_replacements >= 1);
  await oldConnectionClosed;
  second.socket.close();
});
