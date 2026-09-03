const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

test('业务运行时拒绝 SQLite，确保实时多实例只使用 PostgreSQL', () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-runtime-config-'));
  const result = spawnSync(process.execPath, ['-e', "require('./src/server')"], {
    cwd: path.join(__dirname, '..'),
    env: {
      ...process.env,
      NODE_ENV: 'development',
      DATABASE_URL: 'postgresql:///watchdog_dev',
      WATCHDOG_DB_DRIVER: 'sqlite',
      WATCHDOG_DATA_DIR: dataDir,
    },
    encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.match(`${result.stdout}\n${result.stderr}`, /WATCHDOG_DB_DRIVER=postgres/);
});
