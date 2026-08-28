const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-logs-'));
process.env.WATCHDOG_DATA_DIR = tmpDir;

const app = require('../src/server');
const db = require('../src/db');

let server;
let base;

before(async () => {
  server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => new Promise((r) => server.close(r)));

const H = { 'Content-Type': 'application/json', 'X-Incident-Id': 'logscene', 'X-Device-Id': 'logs-device', 'X-Actor-Name': 'tester' };
const j = (r) => r.json();

for (const id of ['logscene', 'otherscene']) db.createIncident({ id });

test('POST /api/logs 批量上报并按警情/设备/时间入库', async () => {
  const res = await fetch(`${base}/api/logs`, {
    method: 'POST',
    headers: { ...H, 'X-Device-Id': 'dev-abc' },
    body: JSON.stringify({
      logs: [
        { op_id: 'op-1', level: 'info', stage: 'record_start', msg: '开始录音' },
        { op_id: 'op-1', level: 'info', stage: 'transcribe_ok', msg: '转写成功', data: { text: '张伟，20兆帕', nested: { apiToken: 'secret-token' } } },
        { op_id: 'op-1', level: 'error', stage: 'parse_err', msg: '解析失败 Authorization: Bearer secret-value', data: { code: 500 } },
      ],
    }),
  });
  assert.equal(res.status, 200);
  const body = await j(res);
  assert.equal(body.count, 3);

  const logs = await (await fetch(`${base}/api/logs`, { headers: H })).json();
  assert.equal(logs.length, 3);
  // 新→旧排序：第一条是最后写入的 parse_err
  assert.equal(logs[0].stage, 'parse_err');
  assert.equal(logs[0].device, 'dev-abc');
  assert.equal(logs[0].op_id, 'op-1');
  assert.deepEqual(logs[0].data, { code: 500 });
  assert.equal(logs[1].data.text.text_length, 7);
  assert.equal(logs[1].data.nested.apiToken.apiToken_length, 12);
  assert.doesNotMatch(logs[0].msg, /secret-value/);
  assert.equal(logs[2].msg, '开始录音');
  assert.ok(typeof logs[2].created_at === 'number');
});

test('日志警情隔离：其他警情不可见', async () => {
  await fetch(`${base}/api/logs`, {
    method: 'POST',
    headers: { ...H, 'X-Incident-Id': 'otherscene' },
    body: JSON.stringify({ logs: [{ stage: 'record_start', msg: '别场景' }] }),
  });
  const logs = await (await fetch(`${base}/api/logs`, { headers: H })).json();
  assert.equal(logs.length, 3); // 当前警情数量不变
});

test('GET /api/logs 支持 op_id/device 过滤与 limit', async () => {
  const byOp = await (await fetch(`${base}/api/logs?op_id=op-1`, { headers: H })).json();
  assert.equal(byOp.length, 3);
  assert.ok(byOp.every((l) => l.op_id === 'op-1'));

  const byDevice = await (await fetch(`${base}/api/logs?device=dev-abc`, { headers: H })).json();
  assert.equal(byDevice.length, 3);
  assert.ok(byDevice.every((l) => l.device === 'dev-abc'));

  const limited = await (await fetch(`${base}/api/logs?limit=1`, { headers: H })).json();
  assert.equal(limited.length, 1);
});

test('POST /api/logs 参数校验：非数组/超量/空 stage 拒绝或忽略', async () => {
  let res = await fetch(`${base}/api/logs`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ logs: 'x' }),
  });
  assert.equal(res.status, 400);

  res = await fetch(`${base}/api/logs`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ logs: Array.from({ length: 101 }, (_, i) => ({ stage: `s${i}`, msg: 'x' })) }),
  });
  assert.equal(res.status, 400);

  // 空 stage 的记录被忽略，不报错
  res = await fetch(`${base}/api/logs`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ logs: [{ stage: '', msg: 'bad' }, { stage: 'ok_stage', msg: 'good' }] }),
  });
  assert.equal(res.status, 200);
  assert.equal((await j(res)).count, 1);
});

test('DELETE /api/logs 清空当前警情日志', async () => {
  const forbidden = await fetch(`${base}/api/logs`, { method: 'DELETE', headers: H });
  assert.equal(forbidden.status, 403);
  assert.equal((await forbidden.json()).code, 'MANAGEMENT_REQUIRED');
  const del = await (await fetch(`${base}/api/logs`, {
    method: 'DELETE',
    headers: { ...H, 'X-Management-Token': 'test-management-token' },
  })).json();
  assert.ok(del.deleted >= 4);
  const logs = await (await fetch(`${base}/api/logs`, { headers: H })).json();
  assert.equal(logs.length, 0);
});

test('服务端埋点：X-Op-Id 下 entry_created / entry_conflict / entry_exited', async () => {
  const opHeaders = { ...H, 'X-Op-Id': 'op-srv-1', 'X-Device-Id': 'dev-srv' };

  // 进场 → entry_created
  const created = await (await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: opHeaders,
    body: JSON.stringify({ name: '赵磊', pressure_mpa: 20, raw_text: '赵磊，20兆帕' }),
  })).json();

  // 重复进场 → entry_conflict
  const dup = await fetch(`${base}/api/entries`, {
    method: 'POST',
    headers: opHeaders,
    body: JSON.stringify({ name: '赵磊', pressure_mpa: 18 }),
  });
  assert.equal(dup.status, 409);

  // 出场 → entry_exited
  await fetch(`${base}/api/entries/${created.id}/exit`, { method: 'POST', headers: opHeaders });

  // 不存在的记录出场 → exit_missing
  const miss = await fetch(`${base}/api/entries/nope/exit`, { method: 'POST', headers: opHeaders });
  assert.equal(miss.status, 404);

  const logs = await (await fetch(`${base}/api/logs?op_id=op-srv-1`, { headers: H })).json();
  const stages = logs.map((l) => l.stage);
  assert.ok(stages.includes('entry_created'), `应有 entry_created: ${stages}`);
  assert.ok(stages.includes('entry_conflict'), `应有 entry_conflict: ${stages}`);
  assert.ok(stages.includes('entry_exited'), `应有 entry_exited: ${stages}`);
  assert.ok(stages.includes('exit_missing'), `应有 exit_missing: ${stages}`);
  assert.ok(logs.every((l) => l.device === 'dev-srv'));

  const createdLog = logs.find((l) => l.stage === 'entry_created');
  assert.equal(createdLog.data.name, '赵磊');
  assert.equal(createdLog.data.pressureMpa, 20);
  assert.equal(createdLog.data.entryId, created.id);
});
