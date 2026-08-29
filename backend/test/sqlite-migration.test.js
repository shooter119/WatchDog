const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

test('旧版 SQLite entries 表可启动升级并保留新计算字段', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-sqlite-migration-'));
  const script = `
    const { DatabaseSync } = require('node:sqlite');
    const path = require('path');
    const db = new DatabaseSync(path.join(process.env.WATCHDOG_DATA_DIR, 'watchdog.db'));
    db.exec("CREATE TABLE entries (" +
      "id TEXT PRIMARY KEY, name TEXT NOT NULL, pressure_mpa REAL, " +
      "duration_min INTEGER NOT NULL DEFAULT 0, entry_at INTEGER NOT NULL, " +
      "exit_at INTEGER NOT NULL, exited_at INTEGER, source TEXT NOT NULL DEFAULT 'voice', " +
      "raw_text TEXT, created_at INTEGER NOT NULL)");
    db.close();
    const repository = require('./src/db-sqlite');
    const entry = repository.createEntry({
      id: 'migration-entry', scene: 'migration-incident', name: '迁移测试',
      pressureMpa: 20, durationMin: 17, entryAtMs: 1000, exitAtMs: 1020000,
      cylinderVolL: 9, consumptionLpm: 40,
    });
    process.stdout.write(JSON.stringify(entry));
  `;
  const result = spawnSync(process.execPath, ['-e', script], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, WATCHDOG_DATA_DIR: tmpDir },
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const entry = JSON.parse(result.stdout);
  assert.equal(entry.scene, 'migration-incident');
  assert.equal(entry.cylinder_vol_l, 9);
  assert.equal(entry.consumption_lpm, 40);
});

test('旧版 SQLite 警情迁移可重复启动且不新增警情', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-sqlite-legacy-repeat-'));
  const script = `
    const { DatabaseSync } = require('node:sqlite');
    const path = require('path');
    const dbPath = path.join(process.env.WATCHDOG_DATA_DIR, 'watchdog.db');
    if (process.env.WATCHDOG_INIT_LEGACY === '1') {
      const db = new DatabaseSync(dbPath);
      db.exec("CREATE TABLE entries (" +
        "id TEXT PRIMARY KEY, scene TEXT NOT NULL, name TEXT NOT NULL, pressure_mpa REAL, " +
        "duration_min INTEGER NOT NULL DEFAULT 0, entry_at INTEGER NOT NULL, " +
        "exit_at INTEGER NOT NULL, exited_at INTEGER, source TEXT NOT NULL DEFAULT 'voice', " +
        "raw_text TEXT, created_at INTEGER NOT NULL)");
      db.prepare("INSERT INTO entries (id, scene, name, duration_min, entry_at, exit_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
        .run('legacy-entry', 'legacy-scene', '迁移测试', 17, 1000, 1020000, 1000);
      db.close();
    }
    require('./src/db-sqlite');
    const db = new DatabaseSync(dbPath);
    const incidentCount = db.prepare('SELECT COUNT(*) AS count FROM incidents').get().count;
    const entry = db.prepare('SELECT scene FROM entries WHERE id = ?').get('legacy-entry');
    process.stdout.write(JSON.stringify({ incidentCount, scene: entry.scene }));
  `;
  const run = (init = false) => spawnSync(process.execPath, ['-e', script], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, WATCHDOG_DATA_DIR: tmpDir, WATCHDOG_INIT_LEGACY: init ? '1' : '0' },
    encoding: 'utf8',
  });
  const first = run(true);
  assert.equal(first.status, 0, first.stderr || first.stdout);
  const firstState = JSON.parse(first.stdout);
  const second = run(false);
  assert.equal(second.status, 0, second.stderr || second.stdout);
  const secondState = JSON.parse(second.stdout);
  assert.equal(firstState.incidentCount, 1);
  assert.equal(secondState.incidentCount, 1);
  assert.equal(secondState.scene, firstState.scene);
  assert.notEqual(secondState.scene, 'legacy-scene');
});

test('旧版 SQLite 警情迁移失败时回滚已创建的警情', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-sqlite-legacy-rollback-'));
  const script = `
    const { DatabaseSync } = require('node:sqlite');
    const path = require('path');
    const dbPath = path.join(process.env.WATCHDOG_DATA_DIR, 'watchdog.db');
    const db = new DatabaseSync(dbPath);
    db.exec("CREATE TABLE entries (" +
      "id TEXT PRIMARY KEY, scene TEXT NOT NULL, name TEXT NOT NULL, pressure_mpa REAL, " +
      "duration_min INTEGER NOT NULL DEFAULT 0, entry_at INTEGER NOT NULL, " +
      "exit_at INTEGER NOT NULL, exited_at INTEGER, source TEXT NOT NULL DEFAULT 'voice', " +
      "raw_text TEXT, created_at INTEGER NOT NULL)");
    db.prepare("INSERT INTO entries (id, scene, name, duration_min, entry_at, exit_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
      .run('rollback-entry', 'rollback-scene', '回滚测试', 1, 1000, 2000, 1000);
    db.exec("CREATE TRIGGER fail_legacy_scene_update BEFORE UPDATE ON entries BEGIN SELECT RAISE(ABORT, 'migration test failure'); END");
    db.close();
    let failed = false;
    try { require('./src/db-sqlite'); } catch (_) { failed = true; }
    const check = new DatabaseSync(dbPath);
    const incidentCount = check.prepare('SELECT COUNT(*) AS count FROM incidents').get().count;
    const entry = check.prepare('SELECT scene FROM entries WHERE id = ?').get('rollback-entry');
    process.stdout.write(JSON.stringify({ failed, incidentCount, scene: entry.scene }));
  `;
  const result = spawnSync(process.execPath, ['-e', script], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, WATCHDOG_DATA_DIR: tmpDir },
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const state = JSON.parse(result.stdout);
  assert.equal(state.failed, true);
  assert.equal(state.incidentCount, 0);
  assert.equal(state.scene, 'rollback-scene');
});
