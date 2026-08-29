const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

test('原子 RPC 未启用操作账本时拒绝启动，避免重试造成重复写入', () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-runtime-config-'));
  const result = spawnSync(process.execPath, ['-e', "require('./src/server')"], {
    cwd: path.join(__dirname, '..'),
    env: {
      ...process.env,
      NODE_ENV: 'test',
      WATCHDOG_DB_DRIVER: 'sqlite',
      WATCHDOG_DATA_DIR: dataDir,
      WATCHDOG_ATOMIC_OPS_ENABLED: '1',
      WATCHDOG_OPERATION_LEDGER_ENABLED: '0',
    },
    encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.match(`${result.stdout}\n${result.stderr}`, /WATCHDOG_ATOMIC_OPS_ENABLED.*WATCHDOG_OPERATION_LEDGER_ENABLED/);
});
