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
