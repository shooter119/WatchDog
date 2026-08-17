const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-concurrency-'));
process.env.WATCHDOG_DATA_DIR = tmpDir;
process.env.WATCHDOG_SQLITE_JOURNAL_MODE = 'WAL';
process.env.WATCHDOG_SQLITE_BUSY_TIMEOUT_MS = '2000';

const db = require('../src/db');
const children = new Set();

function waitForOutput(child, marker) {
  return new Promise((resolve, reject) => {
    let output = '';
    const onData = (chunk) => {
      output += chunk.toString();
      if (output.includes(marker)) {
        child.stdout.off('data', onData);
        resolve(output);
      }
    };
    child.stdout.on('data', onData);
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      if (!output.includes(marker)) reject(new Error(`子进程未输出 ${marker}: code=${code} signal=${signal}`));
    });
  });
}

function startLockProcess(holdMs) {
  const script = `
    const { DatabaseSync } = require('node:sqlite');
    const database = new DatabaseSync(process.env.WATCHDOG_DATA_DIR + '/watchdog.db');
    database.exec('BEGIN IMMEDIATE');
    process.stdout.write('READY\\n');
    setTimeout(() => {
      database.exec('COMMIT');
      database.close();
      process.stdout.write('DONE\\n');
    }, Number(process.env.HOLD_MS));
  `;
  const child = spawn(process.execPath, ['-e', script], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, HOLD_MS: String(holdMs) },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  children.add(child);
  return child;
}

function runWorker(script) {
  const child = spawn(process.execPath, ['-e', script], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  children.add(child);
  return new Promise((resolve, reject) => {
    let output = '';
    let error = '';
    child.stdout.on('data', (chunk) => { output += chunk.toString(); });
    child.stderr.on('data', (chunk) => { error += chunk.toString(); });
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      children.delete(child);
      if (code !== 0) return reject(new Error(`worker failed code=${code} signal=${signal}: ${error}`));
      try {
        const line = output.trim().split('\n').filter(Boolean).at(-1);
        resolve(JSON.parse(line));
      } catch (e) {
        reject(new Error(`worker output invalid: ${output}; ${e.message}`));
      }
    });
  });
}

function waitForExit(child) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise((resolve) => child.once('exit', resolve));
}

after(async () => {
  for (const child of children) {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    await waitForExit(child);
  }
});

test('共享 SQLite 外部写锁释放后，busy_timeout 能让写入成功', async () => {
  const child = startLockProcess(350);
  await waitForOutput(child, 'READY');
  const started = Date.now();
  db.addLog({ scene: 'lock-test', stage: 'write-after-lock', msg: 'ok' });
  const elapsed = Date.now() - started;
  assert.ok(elapsed >= 250, `写入没有等待外部锁，耗时 ${elapsed}ms`);
  assert.ok(elapsed < 2000, `写入超过 busy_timeout，耗时 ${elapsed}ms`);
  await waitForExit(child);
  children.delete(child);
});

test('并发同名进场由事务串行化，最终只保留一条在场记录', async () => {
  const incidentId = 'concurrent-entry-incident';
  db.createIncident({ id: incidentId });
  const script = `
    const { randomUUID } = require('node:crypto');
    const db = require('./src/db');
    const now = Date.now();
    const result = db.createEntryWithEvent({
      entry: { id: randomUUID(), scene: process.env.INCIDENT_ID, name: '并发队员', pressureMpa: 20, durationMin: 17, entryAtMs: now, exitAtMs: now + 1020000, source: 'test' },
      event: { incidentId: process.env.INCIDENT_ID, type: 'entry', occurredAt: now, clientOpId: randomUUID(), payload: { name: '并发队员' } },
    });
    process.stdout.write(JSON.stringify({ entryId: result.entry?.id || null, existingId: result.existing?.id || null }));
  `;
  const results = await Promise.all([
    runWorker(script.replaceAll('process.env.INCIDENT_ID', JSON.stringify(incidentId))),
    runWorker(script.replaceAll('process.env.INCIDENT_ID', JSON.stringify(incidentId))),
  ]);
  assert.equal(results.filter((item) => item.entryId).length, 1);
  assert.equal(results.filter((item) => item.existingId).length, 1);
  assert.equal(db.listEntries({ scene: incidentId, activeOnly: true }).length, 1);
  assert.equal(db.listIncidentEvents(incidentId).length, 1);
});

test('并发相同 client_op_id 只落一条事件并返回同一事件', async () => {
  const incidentId = 'concurrent-event-incident';
  db.createIncident({ id: incidentId });
  const operationId = 'same-client-op';
  const script = `
    const db = require('./src/db');
    const result = db.appendIncidentEvent({ incidentId: '${incidentId}', type: 'note', clientOpId: '${operationId}', payload: { text: '幂等' } });
    process.stdout.write(JSON.stringify({ id: result.id }));
  `;
  const results = await Promise.all([runWorker(script), runWorker(script)]);
  assert.equal(results[0].id, results[1].id);
  assert.equal(db.listIncidentEvents(incidentId).length, 1);
});
